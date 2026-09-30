import Foundation

public enum WallpaperCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case noArchiveCandidate
    case noFavorites
    case noUsableFavorite
    case unsupportedMediaType
    case missingImageURL
    case updateInProgress

    public var errorDescription: String? {
        switch self {
        case .noArchiveCandidate:
            return "No usable APOD was found in the archive."
        case .noFavorites:
            return "No favorites yet."
        case .noUsableFavorite:
            return "Your favorites do not contain a usable image yet."
        case .unsupportedMediaType:
            return "This APOD media type cannot be used as a wallpaper."
        case .missingImageURL:
            return "This APOD does not provide an image URL."
        case .updateInProgress:
            return "Wait for the current wallpaper update to finish before clearing the cache."
        }
    }
}

@MainActor
public protocol WallpaperApplying: AnyObject, Sendable {
    func apply(imageURL: URL, presentation: WallpaperPresentation) throws
}

@MainActor
public final class WallpaperCoordinator {
    public private(set) var latestAPOD: APOD?
    public private(set) var currentImageURL: URL?
    public private(set) var lastError: Error?
    public private(set) var lastSuccessfulCheckAt: Date?
    public private(set) var emptyStateMessage: String?
    public private(set) var isUpdating = false
    public var onChange: (() -> Void)?
    public private(set) var operationMessage = "Ready"
    public private(set) var downloadFraction: Double?

    public var wallpaperSource: WallpaperSource
    public var updateInterval: UpdateInterval
    public var nonImageBehavior: NonImageBehavior
    public var preferHighestResolution: Bool
    public var wallpaperPresentation: WallpaperPresentation
    public var automaticUpdates: Bool

    private var client: any APODFetching
    private let store: APODStore
    private let wallpaper: any WallpaperApplying
    private let imageDownloader: any ImageDownloading
    private var navigationCursorID: Int64?
    private var operationTask: Task<Void, Never>?
    private var activeDownloadID: UUID?

    public init(
        client: any APODFetching,
        store: APODStore,
        wallpaper: any WallpaperApplying,
        imageDownloader: any ImageDownloading = URLSessionImageDownloader(),
        settings: APODSettings = APODSettings()
    ) {
        self.client = client
        self.store = store
        self.wallpaper = wallpaper
        self.imageDownloader = imageDownloader
        self.wallpaperSource = settings.wallpaperSource
        self.updateInterval = settings.updateInterval
        self.nonImageBehavior = settings.nonImageBehavior
        self.preferHighestResolution = settings.preferHighestResolution
        self.wallpaperPresentation = settings.wallpaperPresentation
        self.automaticUpdates = settings.automaticUpdates
        self.navigationCursorID = store.latestNavigationEntry()?.id

        if let navigationEntry = store.latestNavigationEntry(),
           let record = store.record(for: navigationEntry.date) {
            self.latestAPOD = record.apod
            self.currentImageURL = store.cachedImageURL(for: record.apod.date)
        }
    }

    public var settings: APODSettings {
        APODSettings(
            wallpaperSource: wallpaperSource,
            updateInterval: updateInterval,
            nonImageBehavior: nonImageBehavior,
            preferHighestResolution: preferHighestResolution,
            wallpaperPresentation: wallpaperPresentation,
            automaticUpdates: automaticUpdates
        )
    }

    public var currentRecord: APODRecord? {
        guard let latestAPOD else {
            return nil
        }
        return store.record(for: latestAPOD.date)
    }

    public var isCurrentFavorite: Bool {
        currentRecord?.isFavorite ?? false
    }
    public func isFavorite(date: String) -> Bool {
        store.record(for: date)?.isFavorite ?? false
    }

    public var canGoPrevious: Bool {
        guard let navigationCursorID else { return false }
        return store.navigationEntry(before: navigationCursorID) != nil
    }

    public func setClient(_ client: any APODFetching) {
        self.client = client
    }

    public func cancelUpdate() {
        guard isUpdating else { return }
        operationTask?.cancel()
        operationMessage = "Cancelling…"
        onChange?()
    }

    public func reapplyCurrent() async {
        guard let latestAPOD else { return }
        await runOperation(message: "Preparing current wallpaper…") {
            if let record = self.store.record(for: latestAPOD.date) {
                if record.apod.mediaType != .image, record.cachedImageSourceURL == nil,
                   let currentImageURL = self.currentImageURL {
                    self.setOperationMessage("Applying current wallpaper…")
                    try Task.checkCancellation()
                    try self.wallpaper.apply(
                        imageURL: currentImageURL,
                        presentation: self.wallpaperPresentation
                    )
                } else {
                    _ = try await self.displayHistorical(record, recordHistory: false)
                }
            } else {
                _ = try await self.display(latestAPOD, recordHistory: false)
            }
        }
    }


    public func recentRecords() -> [APODRecord] {
        store.recentRecords()
    }

    public func favoriteRecords() -> [APODRecord] {
        store.favoriteRecords()
    }

    public func restoreCachedWallpaper() {
        guard !isUpdating,
              let navigationEntry = store.latestNavigationEntry(),
              let record = store.record(for: navigationEntry.date),
              let imageURL = store.cachedImageURL(for: record.apod.date),
              record.apod.mediaType == .image || record.cachedImageSourceURL != nil else {
            return
        }
        isUpdating = true
        lastError = nil
        operationMessage = "Applying cached wallpaper…"
        onChange?()
        do {
            try wallpaper.apply(imageURL: imageURL, presentation: wallpaperPresentation)
            navigationCursorID = navigationEntry.id
            latestAPOD = record.apod
            currentImageURL = imageURL
            emptyStateMessage = nil
            operationMessage = "Wallpaper restored"
        } catch {
            lastError = error
            operationMessage = error.localizedDescription
        }
        isUpdating = false
        onChange?()
    }

    public func refresh(force: Bool = false) async {
        await runOperation(message: "Fetching APOD…") {
            try await self.refreshSelectedSource(force: force)
        }
    }

    public func nextWallpaper() async {
        await runOperation(message: "Preparing next wallpaper…") {
            if let cursor = self.navigationCursorID,
               let entry = self.store.navigationEntry(after: cursor) {
                try await self.displayNavigationEntry(entry)
            } else {
                self.setOperationMessage("Fetching APOD…")
                try await self.refreshSelectedSource(force: true)
            }
        }
    }

    public func previousWallpaper() async {
        guard let cursor = navigationCursorID,
              let entry = store.navigationEntry(before: cursor) else { return }
        await runOperation(message: "Preparing previous wallpaper…") {
            try await self.displayNavigationEntry(entry)
        }
    }

    public func showAgain(date: String) async {
        guard let record = store.record(for: date) else { return }
        await runOperation(message: "Preparing wallpaper…") {
            _ = try await self.displayHistorical(record, recordHistory: true)
        }
    }

    public func setFavorite(for date: String, isFavorite: Bool) {
        do {
            try store.markFavorite(date: date, isFavorite: isFavorite)
            lastError = nil
        } catch {
            lastError = error
        }
        onChange?()
    }

    @discardableResult
    public func toggleCurrentFavorite() -> Bool {
        guard let latestAPOD else {
            return false
        }
        let newValue = !isCurrentFavorite
        setFavorite(for: latestAPOD.date, isFavorite: newValue)
        return newValue
    }

    @discardableResult
    public func clearImageCache() -> Result<Int64, Error> {
        guard !isUpdating else {
            return .failure(WallpaperCoordinatorError.updateInProgress)
        }
        do {
            try store.clearImageCache()
            currentImageURL = nil
            lastError = nil
            operationMessage = "Image cache cleared"
            onChange?()
            return .success(store.cacheSizeBytes())
        } catch {
            lastError = error
            operationMessage = error.localizedDescription
            onChange?()
            return .failure(error)
        }
    }

    public func cacheSizeBytes() -> Int64 {
        store.cacheSizeBytes()
    }

    private func runOperation(
        message: String,
        operation: @escaping @MainActor () async throws -> Void
    ) async {
        guard !isUpdating, !Task.isCancelled else { return }
        isUpdating = true
        lastError = nil
        let previousEmptyState = emptyStateMessage
        emptyStateMessage = nil
        downloadFraction = nil
        operationMessage = message
        let task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                self.operationMessage = self.emptyStateMessage ?? "Wallpaper updated"
            } catch {
                if Task.isCancelled || error is CancellationError
                    || (error as? URLError)?.code == .cancelled {
                    self.lastError = nil
                    self.emptyStateMessage = previousEmptyState
                    self.operationMessage = "Update cancelled"
                } else {
                    self.lastError = error
                    self.operationMessage = error.localizedDescription
                }
            }
            self.activeDownloadID = nil
            self.downloadFraction = nil
            self.isUpdating = false
            self.operationTask = nil
            self.onChange?()
        }
        operationTask = task
        onChange?()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func setOperationMessage(_ message: String) {
        operationMessage = message
        downloadFraction = nil
        onChange?()
    }

    private func refreshSelectedSource(force: Bool) async throws {
        switch wallpaperSource {
        case .today:
            try await refreshToday(force: force)
        case .archive:
            try await refreshArchive()
        case .favorites:
            try await refreshFavorites()
        }
        try Task.checkCancellation()
        lastSuccessfulCheckAt = Date()
    }

    private func refreshToday(force: Bool) async throws {
        let apod = try await client.fetchLatest()
        try Task.checkCancellation()

        if !force,
           apod.date == latestAPOD?.date,
           ((currentImageURL != nil
             && store.record(for: apod.date)?.cachedImageSourceURL == imageSourceURL(for: apod))
            || (apod.mediaType != .image
                && effectiveNonImageBehavior(for: .today) == .keepCurrent)) {
            try store.save(apod)
            latestAPOD = apod
            if apod.mediaType != .image,
               effectiveNonImageBehavior(for: .today) == .keepCurrent {
                emptyStateMessage = "Today's APOD is not an image. Keeping the current wallpaper."
            }
            return
        }
        _ = try await display(apod, recordHistory: true)
    }

    private func refreshArchive() async throws {
        var candidates = try await client.fetchRandom(count: 20)
        try Task.checkCancellation()
        if let latestAPOD,
           !candidates.contains(where: { $0.date == latestAPOD.date }) {
            candidates.append(latestAPOD)
        }
        let seenDates = store.seenDates()
        let currentDate = latestAPOD?.date
        let eligible = candidates.filter {
            $0.date != currentDate && canAttempt($0, for: .archive)
        }
        let unseen = eligible.filter { !seenDates.contains($0.date) }
        let orderedCandidates = unseen.shuffled() + eligible.filter {
            !unseen.contains($0)
        }.shuffled()

        guard !orderedCandidates.isEmpty else {
            throw WallpaperCoordinatorError.noArchiveCandidate
        }

        var lastFailure: Error?
        for apod in orderedCandidates {
            do {
                if try await display(apod, recordHistory: true) {
                    return
                }
            } catch {
                try Task.checkCancellation()
                lastFailure = error
            }
        }
        throw lastFailure ?? WallpaperCoordinatorError.noArchiveCandidate
    }

    private func refreshFavorites() async throws {
        let records = favoriteRecords()
        guard !records.isEmpty else {
            emptyStateMessage = WallpaperCoordinatorError.noFavorites.localizedDescription
            throw WallpaperCoordinatorError.noFavorites
        }

        let currentDate = latestAPOD?.date
        let eligible = records.filter { canAttempt($0.apod, for: .favorites) }
        let candidates = (eligible.count > 1
            ? eligible.filter { $0.apod.date != currentDate }
            : eligible
        ).shuffled()
        guard !candidates.isEmpty else {
            emptyStateMessage = WallpaperCoordinatorError.noUsableFavorite.localizedDescription
            throw WallpaperCoordinatorError.noUsableFavorite
        }

        var lastFailure: Error?
        for record in candidates {
            do {
                if try await display(record.apod, recordHistory: true) {
                    return
                }
            } catch {
                try Task.checkCancellation()
                lastFailure = error
            }
        }
        throw lastFailure ?? WallpaperCoordinatorError.noUsableFavorite
    }

    @discardableResult
    private func display(_ apod: APOD, recordHistory: Bool) async throws -> Bool {
        try Task.checkCancellation()
        guard let sourceURL = imageSourceURL(for: apod) else {
            switch effectiveNonImageBehavior(for: wallpaperSource) {
            case .keepCurrent:
                try store.save(apod)
                latestAPOD = apod
                emptyStateMessage = "Today's APOD is not an image. Keeping the current wallpaper."
                return false
            case .skip:
                try store.save(apod)
                emptyStateMessage = "This APOD is not an image. Keeping the current wallpaper."
                return false
            case .useThumbnail, .automatic:
                throw WallpaperCoordinatorError.missingImageURL
            }
        }
        try await applyImage(for: apod, sourceURL: sourceURL, recordHistory: recordHistory)
        return true
    }

    @discardableResult
    private func displayHistorical(
        _ record: APODRecord,
        recordHistory: Bool
    ) async throws -> Bool {
        let sourceURL = record.apod.mediaType == .image
            ? preferredImageURL(for: record.apod)
            : record.cachedImageSourceURL
        guard let sourceURL else {
            throw WallpaperCoordinatorError.missingImageURL
        }
        try await applyImage(for: record.apod, sourceURL: sourceURL, recordHistory: recordHistory)
        return true
    }

    private func applyImage(for apod: APOD, sourceURL: URL, recordHistory: Bool) async throws {
        try Task.checkCancellation()
        let record = store.record(for: apod.date)
        let imageURL: URL
        let isStaged: Bool
        if record?.cachedImageSourceURL == sourceURL,
           let cachedImageURL = store.cachedImageURL(for: apod.date) {
            imageURL = cachedImageURL
            isStaged = false
        } else {
            let data = try await downloadImage(from: sourceURL)
            try Task.checkCancellation()
            imageURL = try store.stageImageData(data, for: apod.date)
            isStaged = true
        }
        do {
            try Task.checkCancellation()
            setOperationMessage("Applying wallpaper…")
            try Task.checkCancellation()
            try wallpaper.apply(imageURL: imageURL, presentation: wallpaperPresentation)
        } catch {
            if isStaged { store.discardStagedImage(at: imageURL) }
            throw error
        }
        // Applying is synchronous on MainActor. Nothing can interleave between the
        // successful system call and committing the current selection.
        latestAPOD = apod
        currentImageURL = imageURL
        emptyStateMessage = nil
        if isStaged {
            try store.commitImage(at: imageURL, for: apod, sourceURL: sourceURL)
        } else {
            try store.save(apod)
        }
        if recordHistory {
            navigationCursorID = try store.recordShown(apod).id
        } else {
            try store.recordReapplied(apod)
        }
    }

    private func downloadImage(from url: URL) async throws -> Data {
        let downloadID = UUID()
        activeDownloadID = downloadID
        setOperationMessage("Downloading image…")
        defer {
            activeDownloadID = nil
            downloadFraction = nil
        }
        return try await imageDownloader.download(from: url) { [weak self] received, expected in
            Task { @MainActor [weak self] in
                guard let self, self.activeDownloadID == downloadID,
                      self.isUpdating, self.operationTask?.isCancelled == false else { return }
                let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                if expected > 0 {
                    self.downloadFraction = min(1, max(0, Double(received) / Double(expected)))
                    let expectedText = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
                    self.operationMessage = "Downloading image — \(receivedText) of \(expectedText)"
                } else {
                    self.downloadFraction = nil
                    self.operationMessage = "Downloading image — \(receivedText)"
                }
                self.onChange?()
            }
        }
    }

    private func displayNavigationEntry(_ entry: NavigationEntry) async throws {
        guard let record = store.record(for: entry.date) else {
            throw WallpaperCoordinatorError.noArchiveCandidate
        }
        _ = try await displayHistorical(record, recordHistory: false)
        navigationCursorID = entry.id
    }

    private func canAttempt(_ apod: APOD, for source: WallpaperSource) -> Bool {
        switch apod.mediaType {
        case .image:
            return true
        case .video:
            return effectiveNonImageBehavior(for: source) == .useThumbnail
                && apod.thumbnailURL != nil
        case .unknown:
            return false
        }
    }


    private func effectiveNonImageBehavior(for source: WallpaperSource) -> NonImageBehavior {
        guard nonImageBehavior == .automatic else {
            return nonImageBehavior
        }
        return source == .today ? .keepCurrent : .skip
    }

    private func imageSourceURL(for apod: APOD) -> URL? {
        switch apod.mediaType {
        case .image:
            return preferredImageURL(for: apod)
        case .video:
            guard effectiveNonImageBehavior(for: wallpaperSource) == .useThumbnail else {
                return nil
            }
            return apod.thumbnailURL
        case .unknown:
            return nil
        }
    }

    private func preferredImageURL(for apod: APOD) -> URL {
        if preferHighestResolution, let hdURL = apod.hdURL {
            return hdURL
        }
        return apod.url
    }
}
