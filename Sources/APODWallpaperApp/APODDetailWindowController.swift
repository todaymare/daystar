import AppKit
import APODWallpaperCore

@MainActor
final class APODDetailWindowController: NSWindowController {
    private let apod: APOD
    private let coordinator: WallpaperCoordinator
    private let initialImageURL: URL?
    private let favoriteButton = NSButton(title: "Favorite", target: nil, action: nil)
    private let setButton = NSButton(title: "Set Wallpaper", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "Ready")
    private let imageView = NSImageView()
    private let imageNote = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private var loadedImageURL: URL?
    private var hasLoadedImage = false
    private var hasShown = false

    init(apod: APOD, imageURL: URL?, coordinator: WallpaperCoordinator) {
        self.apod = apod
        self.coordinator = coordinator
        self.initialImageURL = imageURL
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(apod.title) — Daystar"
        window.minSize = NSSize(width: 520, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildView()
        updateState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        if !hasShown {
            window?.center()
            hasShown = true
        }
        updateState()
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateState() {
        let busy = coordinator.isUpdating
        favoriteButton.isEnabled = !busy
        setButton.isEnabled = !busy
        statusLabel.stringValue = coordinator.lastError.map { "Couldn’t complete the operation: \($0.localizedDescription)" }
            ?? coordinator.operationMessage
        statusLabel.textColor = coordinator.lastError == nil ? .secondaryLabelColor : .systemRed
        statusLabel.setAccessibilityValue(statusLabel.stringValue)
        statusLabel.toolTip = statusLabel.stringValue
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
        guard !busy else { return }
        favoriteButton.title = coordinator.isFavorite(date: apod.date) ? "Unfavorite" : "Favorite"
        let record = coordinator.recentRecords().first { $0.apod.date == apod.date }
            ?? coordinator.favoriteRecords().first { $0.apod.date == apod.date }
        let availableURL = (record?.cachedImagePath ?? initialImageURL).flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        if !hasLoadedImage || loadedImageURL != availableURL {
            let image = availableURL.flatMap(NSImage.init(contentsOf:))
            imageView.image = image ?? NSImage(systemSymbolName: apod.mediaType == .video ? "play.rectangle" : "photo", accessibilityDescription: "No cached image")
            imageView.contentTintColor = image == nil ? .tertiaryLabelColor : nil
            loadedImageURL = image == nil ? nil : availableURL
            hasLoadedImage = true
        }
        let current = coordinator.latestAPOD?.date == apod.date && coordinator.currentImageURL != nil
        if loadedImageURL != nil {
            imageNote.stringValue = current ? "Cached image · Current wallpaper" : "Cached image · Ready to use as wallpaper"
        } else if apod.mediaType == .video {
            imageNote.stringValue = "Video APOD · No cached wallpaper preview. Daystar uses your video-day setting when applying this item."
        } else if apod.mediaType == .unknown {
            imageNote.stringValue = "Unsupported media · Open the NASA page to view this APOD."
        } else {
            imageNote.stringValue = "Image not downloaded · Set Wallpaper downloads this APOD before applying it."
        }
        setButton.isEnabled = apod.mediaType != .unknown
    }

    @objc private func toggleFavorite(_ sender: Any?) {
        guard !coordinator.isUpdating else { return }
        coordinator.setFavorite(for: apod.date, isFavorite: !coordinator.isFavorite(date: apod.date))
        updateState()
    }

    @objc private func setWallpaper(_ sender: Any?) {
        guard !coordinator.isUpdating else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await coordinator.showAgain(date: apod.date)
            updateState()
        }
    }

    @objc private func openAPOD(_ sender: Any?) {
        NSWorkspace.shared.open(apod.pageURL)
    }

    private func buildView() {
        guard let contentView = window?.contentView else { return }
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        let document = APODDetailDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityLabel(apod.title)
        stack.addArrangedSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.heightAnchor.constraint(equalToConstant: 280)
        ])
        imageNote.font = .systemFont(ofSize: 12)
        imageNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(imageNote)
        imageNote.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let title = NSTextField(wrappingLabelWithString: apod.title)
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.maximumNumberOfLines = 0
        title.isSelectable = true
        stack.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let date = NSTextField(labelWithString: "\(formattedDate(apod.date)) · \(apod.date)")
        date.textColor = .secondaryLabelColor
        date.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(date)
        let creditText = apod.copyright.flatMap { $0.isEmpty ? nil : $0 }
        if let creditText {
            let credit = NSTextField(wrappingLabelWithString: "Image credit: \(creditText)")
            credit.textColor = .secondaryLabelColor
            credit.isSelectable = true
            stack.addArrangedSubview(credit)
            credit.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let heading = NSTextField(labelWithString: "About this APOD")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(heading)
        let explanation = NSTextField(wrappingLabelWithString: apod.explanation.flatMap { $0.isEmpty ? nil : $0 }
            ?? "NASA did not provide an explanation for this APOD.")
        explanation.maximumNumberOfLines = 0
        explanation.font = .systemFont(ofSize: 14)
        explanation.isSelectable = true
        stack.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let provenance = NSTextField(wrappingLabelWithString: "Source: NASA Astronomy Picture of the Day\n\(apod.pageURL.absoluteString)")
        provenance.font = .systemFont(ofSize: 12)
        provenance.textColor = .secondaryLabelColor
        provenance.isSelectable = true
        stack.addArrangedSubview(provenance)
        provenance.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let footer = NSStackView()
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(footer)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        setButton.target = self
        setButton.action = #selector(setWallpaper(_:))
        setButton.bezelStyle = .rounded
        setButton.toolTip = "Apply this APOD, dated \(apod.date), as your wallpaper"
        setButton.setAccessibilityLabel("Set wallpaper for APOD \(apod.date)")
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite(_:))
        favoriteButton.bezelStyle = .rounded
        buttons.addArrangedSubview(setButton)
        buttons.addArrangedSubview(favoriteButton)
        let nasaButton = NSButton(title: "Open NASA", target: self, action: #selector(openAPOD(_:)))
        nasaButton.bezelStyle = .rounded
        nasaButton.toolTip = apod.pageURL.absoluteString
        buttons.addArrangedSubview(nasaButton)
        footer.addArrangedSubview(buttons)
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        progress.setAccessibilityLabel("Wallpaper download progress")
        footer.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.isSelectable = true
        footer.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: "\(value)T00:00:00Z") else { return value }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private final class APODDetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}
