import AppKit
import ImageIO
import APODWallpaperCore

@MainActor
final class RecentWindowController: NSWindowController, NSSearchFieldDelegate {
    private let coordinator: WallpaperCoordinator
    private let showDetails: (APODRecord) -> Void
    private let stackView = NSStackView()
    private let scrollView = NSScrollView()
    private let filterControl = NSSegmentedControl(labels: ["Recents", "Favorites"], trackingMode: .selectOne, target: nil, action: nil)
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Ready")
    private let progress = NSProgressIndicator()
    private var mutationButtons: [NSButton] = []
    private var displayedRecords: [APODRecord] = []
    private var loadedRecords: [APODRecord]?
    private var loadedCurrentDate: String?
    private var loadedQuery = ""
    private var loadedFilter = -1
    private var hasShown = false

    init(coordinator: WallpaperCoordinator, showDetails: @escaping (APODRecord) -> Void) {
        self.coordinator = coordinator
        self.showDetails = showDetails
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daystar Library"
        window.minSize = NSSize(width: 560, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildView()
        updateState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        let firstPresentation = !hasShown
        if !hasShown {
            window?.center()
            hasShown = true
        }
        updateState()
        super.showWindow(sender)
        if firstPresentation {
            window?.makeFirstResponder(searchField)
            window?.contentView?.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateState() {
        let busy = coordinator.isUpdating
        filterControl.isEnabled = !busy
        searchField.isEnabled = !busy
        mutationButtons.forEach { $0.isEnabled = !busy }
        statusLabel.stringValue = coordinator.lastError.map { "Couldn’t complete the operation: \($0.localizedDescription)" }
            ?? coordinator.operationMessage
        statusLabel.textColor = coordinator.lastError == nil ? .secondaryLabelColor : .systemRed
        statusLabel.toolTip = statusLabel.stringValue
        statusLabel.setAccessibilityValue(statusLabel.stringValue)
        progress.isHidden = !busy
        if let fraction = coordinator.downloadFraction {
            progress.isIndeterminate = false
            progress.doubleValue = min(1, max(0, fraction)) * 100
            progress.setAccessibilityValue("\(Int(progress.doubleValue)) percent")
            progress.stopAnimation(nil)
        } else {
            progress.isIndeterminate = true
            if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        }
        guard !busy || loadedRecords == nil else { return }
        reloadIfNeeded()
        mutationButtons.forEach { $0.isEnabled = !busy }
    }

    func controlTextDidChange(_ obj: Notification) {
        updateState()
    }

    private func buildView() {
        guard let contentView = window?.contentView else { return }
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        let title = NSTextField(labelWithString: "Your astronomy library")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        header.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "Revisit wallpapers you’ve shown, or keep favorites for another night.")
        subtitle.textColor = .secondaryLabelColor
        header.addArrangedSubview(subtitle)
        subtitle.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))
        filterControl.setAccessibilityLabel("Library collection")
        toolbar.addArrangedSubview(filterControl)
        searchField.placeholderString = "Search title or date"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search library by title or date")
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(searchField)
        header.addArrangedSubview(toolbar)
        toolbar.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        header.addArrangedSubview(countLabel)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        let document = LibraryDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stackView)

        let footer = NSStackView()
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(footer)
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        progress.setAccessibilityLabel("Wallpaper download progress")
        footer.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.isSelectable = true
        statusLabel.maximumNumberOfLines = 3
        footer.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stackView.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stackView.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
    }

    private func reloadIfNeeded() {
        let records = filterControl.selectedSegment == 1 ? coordinator.favoriteRecords() : coordinator.recentRecords()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDate = coordinator.currentImageURL == nil ? nil : coordinator.latestAPOD?.date
        guard loadedRecords != records || loadedCurrentDate != currentDate || loadedQuery != query || loadedFilter != filterControl.selectedSegment else { return }
        loadedRecords = records
        loadedCurrentDate = currentDate
        loadedQuery = query
        loadedFilter = filterControl.selectedSegment
        displayedRecords = records.filter { record in
            query.isEmpty || record.apod.title.localizedStandardContains(query)
                || record.apod.date.localizedStandardContains(query)
                || formattedDate(record.apod.date).localizedStandardContains(query)
        }
        countLabel.stringValue = query.isEmpty
            ? "\(records.count) \(records.count == 1 ? "item" : "items")"
            : "\(displayedRecords.count) of \(records.count) items"
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        mutationButtons.removeAll()
        if displayedRecords.isEmpty {
            let empty = NSStackView()
            empty.orientation = .vertical
            empty.alignment = .leading
            empty.spacing = 8
            let heading = NSTextField(labelWithString: !query.isEmpty ? "No matching APODs" : (loadedFilter == 1 ? "No favorites yet" : "Your library starts here"))
            heading.font = .systemFont(ofSize: 17, weight: .semibold)
            empty.addArrangedSubview(heading)
            let message = NSTextField(wrappingLabelWithString: !query.isEmpty
                ? "Try a different title, a date such as 2026-09-30, or clear the search field."
                : (loadedFilter == 1 ? "Choose Favorite on an APOD in Recents or its details to save it here." : "Use Next Wallpaper in Daystar to find an APOD. Wallpapers you show will appear here."))
            message.textColor = .secondaryLabelColor
            empty.addArrangedSubview(message)
            stackView.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            message.widthAnchor.constraint(equalTo: empty.widthAnchor).isActive = true
        } else {
            for record in displayedRecords {
                let row = makeRow(record)
                stackView.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            }
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func makeRow(_ record: APODRecord) -> NSView {
        let container = NSBox()
        container.boxType = .custom
        container.borderWidth = 1
        container.borderColor = .separatorColor
        container.cornerRadius = 10
        container.fillColor = .controlBackgroundColor
        container.contentViewMargins = .zero
        container.translatesAutoresizingMaskIntoConstraints = false
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        guard let content = container.contentView else { return container }
        content.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 14
        body.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let cachedURL = record.cachedImagePath.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let image = cachedURL.flatMap(thumbnail)
        let imageView = NSImageView()
        imageView.image = image ?? NSImage(systemSymbolName: record.apod.mediaType == .video ? "play.rectangle" : "photo", accessibilityDescription: "No cached preview")
        imageView.contentTintColor = image == nil ? .tertiaryLabelColor : nil
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.toolTip = image == nil ? "Preview available after downloading the wallpaper" : record.apod.title
        top.addArrangedSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 104),
            imageView.heightAnchor.constraint(equalToConstant: 84)
        ])
        let info = NSStackView()
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 5
        info.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.addArrangedSubview(info)
        let title = NSTextField(wrappingLabelWithString: record.apod.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.maximumNumberOfLines = 2
        info.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true
        let date = NSTextField(labelWithString: "\(formattedDate(record.apod.date)) · \(record.apod.date)")
        date.font = .systemFont(ofSize: 12)
        date.textColor = .secondaryLabelColor
        date.lineBreakMode = .byTruncatingTail
        info.addArrangedSubview(date)
        date.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true
        let creditText = record.apod.copyright.flatMap { $0.isEmpty ? nil : $0 }
        let credit = NSTextField(wrappingLabelWithString: creditText.map { "Credit: \($0)" } ?? "NASA Astronomy Picture of the Day")
        credit.font = .systemFont(ofSize: 12)
        credit.textColor = .secondaryLabelColor
        credit.maximumNumberOfLines = 2
        info.addArrangedSubview(credit)
        credit.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true
        var badges = [cachedURL == nil ? "Needs download" : "Cached"]
        if record.apod.mediaType == .video { badges.append("Video APOD") }
        if record.apod.date == loadedCurrentDate { badges.append("Current wallpaper") }
        let state = NSTextField(wrappingLabelWithString: badges.joined(separator: " · "))
        state.font = .systemFont(ofSize: 11, weight: .medium)
        state.textColor = record.apod.date == loadedCurrentDate ? .controlAccentColor : .secondaryLabelColor
        info.addArrangedSubview(state)
        state.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        let setButton = actionButton(title: "Set Wallpaper", action: #selector(setWallpaper(_:)), date: record.apod.date)
        let favoriteButton = actionButton(title: record.isFavorite ? "Unfavorite" : "Favorite", action: #selector(toggleFavorite(_:)), date: record.apod.date)
        mutationButtons.append(contentsOf: [setButton, favoriteButton])
        actions.addArrangedSubview(setButton)
        actions.addArrangedSubview(favoriteButton)
        actions.addArrangedSubview(actionButton(title: "Details", action: #selector(openDetails(_:)), date: record.apod.date))
        actions.addArrangedSubview(actionButton(title: "Open NASA", action: #selector(openAPOD(_:)), date: record.apod.date))
        body.addArrangedSubview(actions)
        return container
    }

    @objc private func filterChanged(_ sender: Any?) { updateState() }

    @objc private func setWallpaper(_ sender: NSButton) {
        guard !coordinator.isUpdating, let date = sender.identifier?.rawValue else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await coordinator.showAgain(date: date)
            updateState()
        }
    }

    @objc private func toggleFavorite(_ sender: NSButton) {
        guard !coordinator.isUpdating, let date = sender.identifier?.rawValue else { return }
        coordinator.setFavorite(for: date, isFavorite: !coordinator.isFavorite(date: date))
        updateState()
    }

    @objc private func openDetails(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        showDetails(record)
    }

    @objc private func openAPOD(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        NSWorkspace.shared.open(record.apod.pageURL)
    }

    private func record(for button: NSButton) -> APODRecord? {
        guard let date = button.identifier?.rawValue else { return nil }
        return displayedRecords.first { $0.apod.date == date }
    }

    private func actionButton(title: String, action: Selector, date: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(date)
        button.setAccessibilityLabel("\(title), APOD \(date)")
        return button
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: "\(value)T00:00:00Z") else { return value }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 224
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

private final class LibraryDocumentView: NSView {
    override var isFlipped: Bool { true }
}
