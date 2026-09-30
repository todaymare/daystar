import Foundation
import XCTest
@testable import APODWallpaperCore

@MainActor
final class WallpaperCoordinatorTests: XCTestCase {
    func testTodayUsesHighestResolutionAndRecordsSeenState() async throws {
        let directory = try temporaryDirectory()
        let apod = makeAPOD(
            date: "2026-08-27",
            mediaType: .image,
            hdURL: URL(string: "https://example.com/hd.jpg")
        )
        let store = try APODStore(directoryURL: directory)
        let downloader = RecordingDownloader(data: validImageData)
        let wallpaper = RecordingWallpaper()
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: apod, random: []),
            store: store,
            wallpaper: wallpaper,
            imageDownloader: downloader,
            settings: APODSettings(wallpaperSource: .today)
        )

        await coordinator.refresh()

        XCTAssertEqual(downloader.requestedURLs, [apod.hdURL!])
        XCTAssertEqual(store.record(for: apod.date)?.showCount, 1)
        XCTAssertEqual(store.seenDates(), [apod.date])
    }

    func testTodayDoesNotRepeatCurrentAPODOnPeriodicChecks() async throws {
        let directory = try temporaryDirectory()
        let apod = makeAPOD(date: "2026-08-27", mediaType: .image)
        let store = try APODStore(directoryURL: directory)
        let downloader = RecordingDownloader(data: validImageData)
        let wallpaper = RecordingWallpaper()
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: apod, random: []),
            store: store,
            wallpaper: wallpaper,
            imageDownloader: downloader,
            settings: APODSettings(wallpaperSource: .today)
        )

        await coordinator.refresh()
        await coordinator.refresh()

        XCTAssertEqual(downloader.requestedURLs.count, 1)
        XCTAssertEqual(wallpaper.appliedURLs.count, 1)
        XCTAssertEqual(store.record(for: apod.date)?.showCount, 1)
    }

    func testSQLitePersistsFavoritesSeenStateAndRecentMetadata() throws {
        let directory = try temporaryDirectory()
        let apod = makeAPOD(date: "2026-05-20", mediaType: .image)
        let shownAt = Date(timeIntervalSince1970: 1234)
        let store = try APODStore(directoryURL: directory)

        try store.save(apod, imageSourceURL: apod.url)
        _ = try store.recordShown(apod, at: shownAt)
        try store.markFavorite(date: apod.date, isFavorite: true)

        let reopenedStore = try APODStore(directoryURL: directory)
        let record = reopenedStore.record(for: apod.date)
        XCTAssertEqual(record?.isFavorite, true)
        XCTAssertEqual(record?.firstShownAt, shownAt)
        XCTAssertEqual(record?.lastShownAt, shownAt)
        XCTAssertEqual(record?.showCount, 1)
        XCTAssertEqual(reopenedStore.recentRecords().map { $0.apod.date }, [apod.date])
        XCTAssertEqual(reopenedStore.favoriteRecords().map { $0.apod.date }, [apod.date])
    }

    func testArchivePrefersUnseenAPODAndExcludesCurrentDate() async throws {
        let directory = try temporaryDirectory()
        let seen = makeAPOD(date: "2026-05-20", mediaType: .image)
        let unseen = makeAPOD(date: "2026-05-21", mediaType: .image)
        let store = try APODStore(directoryURL: directory)
        try store.save(seen, imageSourceURL: seen.url)
        _ = try store.recordShown(seen)

        let downloader = RecordingDownloader(data: validImageData)
        let wallpaper = RecordingWallpaper()
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: unseen, random: [seen, unseen]),
            store: store,
            wallpaper: wallpaper,
            imageDownloader: downloader,
            settings: APODSettings(wallpaperSource: .archive)
        )

        await coordinator.refresh()

        XCTAssertEqual(coordinator.latestAPOD?.date, unseen.date)
        XCTAssertEqual(store.seenDates(), Set([seen.date, unseen.date]))
    }

    func testFavoritesSourceRedownloadsEvictedFavorite() async throws {
        let directory = try temporaryDirectory()
        let favorite = makeAPOD(date: "2026-05-20", mediaType: .image)
        let store = try APODStore(directoryURL: directory)
        try store.save(favorite, imageSourceURL: favorite.url)
        try store.markFavorite(date: favorite.date, isFavorite: true)
        let downloader = RecordingDownloader(data: validImageData)
        let wallpaper = RecordingWallpaper()
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: favorite, random: []),
            store: store,
            wallpaper: wallpaper,
            imageDownloader: downloader,
            settings: APODSettings(wallpaperSource: .favorites)
        )

        await coordinator.refresh()

        XCTAssertEqual(downloader.requestedURLs, [favorite.url])
    }

    func testTodayVideoKeepsCurrentWallpaperByDefault() async throws {
        let directory = try temporaryDirectory()
        let video = makeAPOD(
            date: "2026-08-27",
            mediaType: .video,
            thumbnailURL: URL(string: "https://example.com/thumb.jpg")
        )
        let downloader = RecordingDownloader(data: validImageData)
        let wallpaper = RecordingWallpaper()
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: video, random: []),
            store: try APODStore(directoryURL: directory),
            wallpaper: wallpaper,
            imageDownloader: downloader,
            settings: APODSettings(wallpaperSource: .today)
        )

        await coordinator.refresh()

        XCTAssertTrue(downloader.requestedURLs.isEmpty)
        XCTAssertTrue(wallpaper.appliedURLs.isEmpty)
        XCTAssertEqual(coordinator.emptyStateMessage, "Today's APOD is not an image. Keeping the current wallpaper.")
    }

    func testArchiveSkipsVideoAndChoosesImage() async throws {
        let directory = try temporaryDirectory()
        let video = makeAPOD(
            date: "2026-05-20",
            mediaType: .video,
            thumbnailURL: URL(string: "https://example.com/thumb.jpg")
        )
        let image = makeAPOD(date: "2026-05-21", mediaType: .image)
        let store = try APODStore(directoryURL: directory)
        let downloader = RecordingDownloader(data: validImageData)
        let wallpaper = RecordingWallpaper()
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: image, random: [video, image]),
            store: store,
            wallpaper: wallpaper,
            imageDownloader: downloader,
            settings: APODSettings(wallpaperSource: .archive)
        )

        await coordinator.refresh()

        XCTAssertEqual(coordinator.latestAPOD?.date, image.date)
        XCTAssertEqual(downloader.requestedURLs, [image.url])
    }

    func testPreviousAndNextUseNavigationHistoryWithoutNewEvents() async throws {
        let directory = try temporaryDirectory()
        let first = makeAPOD(date: "2026-05-20", mediaType: .image)
        let second = makeAPOD(date: "2026-05-21", mediaType: .image)
        let store = try APODStore(directoryURL: directory)
        try store.save(first, imageSourceURL: first.url)
        _ = try store.saveImageData(validImageData, for: first.date)
        _ = try store.recordShown(first, at: Date(timeIntervalSince1970: 1))
        try store.save(second, imageSourceURL: second.url)
        _ = try store.saveImageData(validImageData, for: second.date)
        let lastEntry = try store.recordShown(second, at: Date(timeIntervalSince1970: 2))

        let wallpaper = RecordingWallpaper()
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: second, random: []),
            store: store,
            wallpaper: wallpaper,
            settings: APODSettings(wallpaperSource: .archive)
        )

        await coordinator.previousWallpaper()
        XCTAssertEqual(coordinator.latestAPOD?.date, first.date)
        XCTAssertEqual(store.recentRecords().first?.apod.date, first.date)
        XCTAssertFalse(coordinator.canGoPrevious)
        await coordinator.nextWallpaper()
        XCTAssertEqual(coordinator.latestAPOD?.date, second.date)
        XCTAssertEqual(store.recentRecords().first?.apod.date, second.date)
        XCTAssertEqual(store.latestNavigationEntry(), lastEntry)
        XCTAssertTrue(coordinator.canGoPrevious)
    }

    func testInvalidImageDataNeverEntersCache() throws {
        let directory = try temporaryDirectory()
        let store = try APODStore(directoryURL: directory)

        XCTAssertThrowsError(try store.saveImageData(Data([1, 2, 3]), for: "2026-08-27")) { error in
            XCTAssertEqual(error as? APODStoreError, .invalidImageData)
        }
        XCTAssertNil(store.cachedImageURL(for: "2026-08-27"))
    }

    func testSettingsRoundTrip() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = APODSettingsStore(defaults: defaults)
        let settings = APODSettings(
            wallpaperSource: .favorites,
            updateInterval: .everySixHours,
            nonImageBehavior: .useThumbnail,
            preferHighestResolution: false,
            wallpaperPresentation: .center,
            automaticUpdates: false
        )

        store.save(settings)

        XCTAssertEqual(store.load(), settings)
    }

    func testFailedApplyPreservesCurrentSelectionAndHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeAPOD(date: "2026-05-20", mediaType: .image)
        let second = makeAPOD(date: "2026-05-21", mediaType: .image)
        let store = try APODStore(directoryURL: directory)
        try store.save(first, imageSourceURL: first.url)
        let firstImage = try store.saveImageData(validImageData, for: first.date)
        let firstEntry = try store.recordShown(first, at: Date(timeIntervalSince1970: 1))
        try store.save(second)
        let wallpaper = RecordingWallpaper()
        wallpaper.failure = URLError(.cannotOpenFile)
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: second, random: []),
            store: store,
            wallpaper: wallpaper,
            imageDownloader: RecordingDownloader(data: validImageData)
        )

        await coordinator.showAgain(date: second.date)

        XCTAssertEqual(coordinator.latestAPOD, first)
        XCTAssertEqual(coordinator.currentImageURL, firstImage)
        XCTAssertEqual(store.latestNavigationEntry(), firstEntry)
        XCTAssertEqual(store.recentRecords().map(\.apod.date), [first.date])
        XCTAssertNil(store.cachedImageURL(for: second.date))
        XCTAssertNotNil(coordinator.lastError)
        XCTAssertFalse(coordinator.isUpdating)

        wallpaper.failure = nil
        await coordinator.showAgain(date: second.date)
        XCTAssertEqual(coordinator.latestAPOD, second)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(store.recentRecords().map(\.apod.date), [second.date, first.date])
    }

    func testFailedResolutionChangePreservesCachedCurrentImage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let apod = makeAPOD(
            date: "2026-05-20",
            mediaType: .image,
            hdURL: URL(string: "https://example.com/hd.jpg")
        )
        let store = try APODStore(directoryURL: directory)
        try store.save(apod, imageSourceURL: apod.url)
        let originalImage = try store.saveImageData(validImageData, for: apod.date)
        _ = try store.recordShown(apod)
        let wallpaper = RecordingWallpaper()
        wallpaper.failure = URLError(.cannotOpenFile)
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: apod, random: []),
            store: store,
            wallpaper: wallpaper,
            imageDownloader: RecordingDownloader(data: validImageData)
        )

        await coordinator.reapplyCurrent()

        XCTAssertEqual(coordinator.currentImageURL, originalImage)
        XCTAssertEqual(store.cachedImageURL(for: apod.date), originalImage)
        XCTAssertEqual(store.record(for: apod.date)?.cachedImageSourceURL, apod.url)
        XCTAssertEqual(try Data(contentsOf: originalImage), validImageData)
    }

    func testSingleFlightProgressAndCancellationPreserveCurrentWallpaper() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeAPOD(date: "2026-05-20", mediaType: .image)
        let second = makeAPOD(date: "2026-05-21", mediaType: .image)
        let store = try APODStore(directoryURL: directory)
        let older = makeAPOD(date: "2026-05-19", mediaType: .image)
        try store.save(older, imageSourceURL: older.url)
        _ = try store.saveImageData(validImageData, for: older.date)
        _ = try store.recordShown(older, at: Date(timeIntervalSince1970: 1))
        try store.save(first, imageSourceURL: first.url)
        let originalImage = try store.saveImageData(validImageData, for: first.date)
        let originalEntry = try store.recordShown(first, at: Date(timeIntervalSince1970: 2))
        try store.save(second)
        let downloader = ControlledDownloader()
        let wallpaper = RecordingWallpaper()
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: second, random: []),
            store: store,
            wallpaper: wallpaper,
            imageDownloader: downloader
        )
        let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()
        var sawBusy = false
        var sawCancelledIdle = false
        coordinator.onChange = {
            sawBusy = sawBusy || coordinator.isUpdating
            if let fraction = coordinator.downloadFraction {
                progressContinuation.yield(fraction)
            }
            if !coordinator.isUpdating, coordinator.lastError == nil {
                sawCancelledIdle = true
            }
        }
        let update = Task { await coordinator.showAgain(date: second.date) }
        await downloader.waitForDownload()
        XCTAssertTrue(coordinator.isUpdating)

        await coordinator.refresh(force: true)
        await coordinator.reapplyCurrent()
        await coordinator.previousWallpaper()
        await coordinator.nextWallpaper()
        await coordinator.showAgain(date: first.date)
        let requestCount = await downloader.requestCount
        XCTAssertEqual(requestCount, 1)
        if case .success = coordinator.clearImageCache() {
            XCTFail("Cache clearing must reject an in-flight wallpaper operation")
        }
        XCTAssertEqual(store.cachedImageURL(for: first.date), originalImage)

        await downloader.emitProgress(received: 25, expected: 100)
        var iterator = progressStream.makeAsyncIterator()
        let fraction = await iterator.next()
        XCTAssertEqual(fraction, 0.25)
        XCTAssertEqual(coordinator.latestAPOD, first)
        coordinator.cancelUpdate()
        await update.value
        progressContinuation.finish()

        XCTAssertTrue(sawBusy)
        XCTAssertTrue(sawCancelledIdle)
        XCTAssertFalse(coordinator.isUpdating)
        XCTAssertNil(coordinator.lastError)
        XCTAssertNil(coordinator.downloadFraction)
        XCTAssertEqual(coordinator.latestAPOD, first)
        XCTAssertEqual(coordinator.currentImageURL, originalImage)
        XCTAssertEqual(store.latestNavigationEntry(), originalEntry)
        XCTAssertTrue(wallpaper.appliedURLs.isEmpty)
    }

    func testHistoricalVideoThumbnailReappliesOfflineAfterBehaviorChange() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let thumbnailURL = URL(string: "https://example.com/thumb.jpg")!
        let video = makeAPOD(date: "2026-05-20", mediaType: .video, thumbnailURL: thumbnailURL)
        let store = try APODStore(directoryURL: directory)
        try store.save(video, imageSourceURL: thumbnailURL)
        let cachedImage = try store.saveImageData(validImageData, for: video.date)
        _ = try store.recordShown(video)
        let downloader = RecordingDownloader(data: validImageData)
        let wallpaper = RecordingWallpaper()
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: video, random: []),
            store: store,
            wallpaper: wallpaper,
            imageDownloader: downloader,
            settings: APODSettings(nonImageBehavior: .keepCurrent)
        )

        await coordinator.reapplyCurrent()

        XCTAssertEqual(wallpaper.appliedURLs, [cachedImage])
        XCTAssertTrue(downloader.requestedURLs.isEmpty)
        XCTAssertNil(coordinator.lastError)

        _ = try coordinator.clearImageCache().get()
        await coordinator.showAgain(date: video.date)
        XCTAssertEqual(downloader.requestedURLs, [thumbnailURL])
        XCTAssertEqual(coordinator.latestAPOD, video)
        XCTAssertEqual(store.record(for: video.date)?.cachedImageSourceURL, thumbnailURL)
        XCTAssertNil(coordinator.lastError)
    }

    func testCallerCancellationStopsDownloadWithoutNetworkError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let apod = makeAPOD(date: "2026-05-20", mediaType: .image)
        let downloader = ControlledDownloader()
        let coordinator = WallpaperCoordinator(
            client: StubClient(latest: apod, random: []),
            store: try APODStore(directoryURL: directory),
            wallpaper: RecordingWallpaper(),
            imageDownloader: downloader,
            settings: APODSettings(wallpaperSource: .today)
        )
        let update = Task { await coordinator.refresh() }
        await downloader.waitForDownload()

        update.cancel()
        await update.value

        XCTAssertFalse(coordinator.isUpdating)
        XCTAssertNil(coordinator.lastError)
        XCTAssertNil(coordinator.latestAPOD)
        XCTAssertNil(coordinator.currentImageURL)
        XCTAssertTrue(coordinator.recentRecords().isEmpty)
    }

    private func makeAPOD(
        date: String,
        mediaType: APODMediaType,
        hdURL: URL? = nil,
        thumbnailURL: URL? = nil
    ) -> APOD {
        APOD(
            date: date,
            title: "APOD \(date)",
            explanation: "A test APOD.",
            mediaType: mediaType,
            url: URL(string: "https://example.com/\(date).jpg")!,
            hdURL: hdURL,
            thumbnailURL: thumbnailURL
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var validImageData: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}

private struct StubClient: APODFetching {
    let latest: APOD
    let random: [APOD]

    func fetchLatest() async throws -> APOD {
        latest
    }

    func fetch(date: String) async throws -> APOD {
        random.first(where: { $0.date == date }) ?? latest
    }

    func fetchRandom(count: Int) async throws -> [APOD] {
        Array(random.prefix(count))
    }
}

private final class RecordingDownloader: ImageDownloading, @unchecked Sendable {
    let data: Data
    private(set) var requestedURLs: [URL] = []

    init(data: Data) {
        self.data = data
    }

    func download(
        from url: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Data {
        requestedURLs.append(url)
        return data
    }
}

@MainActor
private final class RecordingWallpaper: WallpaperApplying {
    private(set) var appliedURLs: [URL] = []
    var failure: Error?

    func apply(imageURL: URL, presentation: WallpaperPresentation) throws {
        if let failure { throw failure }
        appliedURLs.append(imageURL)
    }
}

private actor ControlledDownloader: ImageDownloading {
    private(set) var requestCount = 0
    private var pending: CheckedContinuation<Data, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var progress: (@Sendable (Int64, Int64) -> Void)?
    private var isCancelled = false

    func download(
        from url: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                requestCount += 1
                self.progress = progress
                pending = continuation
                started?.resume()
                started = nil
            }
        } onCancel: {
            Task { await self.cancelDownload() }
        }
    }

    func waitForDownload() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func emitProgress(received: Int64, expected: Int64) {
        progress?(received, expected)
    }

    private func cancelDownload() {
        isCancelled = true
        pending?.resume(throwing: CancellationError())
        pending = nil
    }
}
