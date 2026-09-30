import AppKit
import APODWallpaperCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private var settings: APODSettings
    private var launchAtLogin: Bool
    private var isUpdating = false
    private let onSettingsChanged: (APODSettings) -> Void
    private let onLaunchAtLoginChanged: (Bool) -> String?
    private let onClearCache: () -> Result<Int64, Error>
    private let onAPIKeyChanged: (String?) -> Void
    private let sourcePopup = NSPopUpButton()
    private let intervalPopup = NSPopUpButton()
    private let nonImagePopup = NSPopUpButton()
    private let presentationPopup = NSPopUpButton()
    private let qualityButton = NSButton(checkboxWithTitle: "Prefer highest-resolution images", target: nil, action: nil)
    private let automaticButton = NSButton(checkboxWithTitle: "Update wallpaper automatically", target: nil, action: nil)
    private let launchButton = NSButton(checkboxWithTitle: "Launch Daystar at login", target: nil, action: nil)
    private let apiKeyField = NSSecureTextField()
    private let saveKeyButton = NSButton(title: "Save Key", target: nil, action: nil)
    private let resetKeyButton = NSButton(title: "Reset to DEMO_KEY", target: nil, action: nil)
    private let clearCacheButton = NSButton(title: "Clear Downloaded Image Cache…", target: nil, action: nil)
    private let sourceDescription = NSTextField(wrappingLabelWithString: "")
    private let nonImageDescription = NSTextField(wrappingLabelWithString: "")
    private let cacheLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Changes apply immediately. Use Save Key to apply an edited NASA key.")

    init(
        settings: APODSettings,
        launchAtLogin: Bool,
        cacheSizeBytes: Int64,
        apiKey: String?,
        onSettingsChanged: @escaping (APODSettings) -> Void,
        onLaunchAtLoginChanged: @escaping (Bool) -> String?,
        onClearCache: @escaping () -> Result<Int64, Error>,
        onAPIKeyChanged: @escaping (String?) -> Void
    ) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        self.onSettingsChanged = onSettingsChanged
        self.onLaunchAtLoginChanged = onLaunchAtLoginChanged
        self.onClearCache = onClearCache
        self.onAPIKeyChanged = onAPIKeyChanged
        apiKeyField.stringValue = apiKey ?? ""

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 610),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daystar Settings"
        window.minSize = NSSize(width: 620, height: 610)
        super.init(window: window)
        buildView(cacheSizeBytes: cacheSizeBytes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }
    func updateState(isUpdating: Bool) {
        self.isUpdating = isUpdating
        sourcePopup.isEnabled = !isUpdating
        presentationPopup.isEnabled = !isUpdating
        qualityButton.isEnabled = !isUpdating
        nonImagePopup.isEnabled = !isUpdating
        apiKeyField.isEnabled = !isUpdating
        saveKeyButton.isEnabled = !isUpdating
        resetKeyButton.isEnabled = !isUpdating
        clearCacheButton.isEnabled = !isUpdating
    }


    @objc private func sourceChanged(_ sender: Any?) {
        guard let source = WallpaperSource.allCases[safe: sourcePopup.indexOfSelectedItem] else { return }
        settings.wallpaperSource = source
        emitSettings()
    }

    @objc private func intervalChanged(_ sender: Any?) {
        guard let interval = UpdateInterval.allCases[safe: intervalPopup.indexOfSelectedItem] else { return }
        settings.updateInterval = interval
        emitSettings()
    }

    @objc private func nonImageChanged(_ sender: Any?) {
        guard let behavior = NonImageBehavior.allCases[safe: nonImagePopup.indexOfSelectedItem] else { return }
        settings.nonImageBehavior = behavior
        emitSettings()
    }

    @objc private func presentationChanged(_ sender: Any?) {
        guard let presentation = WallpaperPresentation.allCases[safe: presentationPopup.indexOfSelectedItem] else { return }
        settings.wallpaperPresentation = presentation
        emitSettings()
    }

    @objc private func qualityChanged(_ sender: NSButton) {
        settings.preferHighestResolution = sender.state == .on
        emitSettings()
    }

    @objc private func automaticChanged(_ sender: NSButton) {
        settings.automaticUpdates = sender.state == .on
        emitSettings()
    }

    @objc private func launchChanged(_ sender: NSButton) {
        let requested = sender.state == .on
        if let error = onLaunchAtLoginChanged(requested) {
            sender.state = launchAtLogin ? .on : .off
            setStatus("Could not change launch at login: \(error)", isError: true)
        } else {
            launchAtLogin = requested
            setStatus(requested ? "Daystar will launch at login." : "Launch at login is off.")
        }
    }

    @objc private func saveAPIKey(_ sender: Any?) {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyField.stringValue = key
        onAPIKeyChanged(key.isEmpty ? nil : key)
        setStatus(key.isEmpty
            ? "Using NASA’s built-in DEMO_KEY. New requests will use this key."
            : "NASA key saved locally. NASA will verify it on the next request.")
    }

    @objc private func resetAPIKey(_ sender: Any?) {
        apiKeyField.stringValue = ""
        saveAPIKey(sender)
    }

    @objc private func openNASAKeys(_ sender: Any?) {
        guard let url = URL(string: "https://api.nasa.gov"), NSWorkspace.shared.open(url) else {
            setStatus("Could not open the NASA API website. Visit api.nasa.gov in your browser.", isError: true)
            return
        }
    }

    @objc private func clearCache(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear downloaded images?"
        alert.informativeText = "Daystar will download images again when needed. Your settings, favorites, and browsing history will be kept. The current desktop wallpaper will not change."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Cache")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard !self.isUpdating else {
                self.setStatus("Wait for the wallpaper update to finish before clearing downloaded images.", isError: true)
                return
            }
            switch self.onClearCache() {
            case .success(let remainingBytes):
                self.cacheLabel.stringValue = "Downloaded images: \(self.formattedBytes(remainingBytes))"
                self.setStatus("Downloaded image cache cleared. Favorites and history were kept.")
            case .failure(let error):
                self.setStatus("Could not clear the image cache: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func buildView(cacheSizeBytes: Int64) {
        guard let contentView = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Make Daystar yours")
        title.font = .boldSystemFont(ofSize: 20)
        title.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(title)

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabs)
        let wallpaperTab = NSTabViewItem(identifier: "wallpaper")
        wallpaperTab.label = "Wallpaper"
        wallpaperTab.view = wallpaperView()
        tabs.addTabViewItem(wallpaperTab)
        let applicationTab = NSTabViewItem(identifier: "application")
        applicationTab.label = "App & NASA"
        applicationTab.view = applicationView(cacheSizeBytes: cacheSizeBytes)
        tabs.addTabViewItem(applicationTab)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.maximumNumberOfLines = 0
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setAccessibilityIdentifier("settingsStatus")
        contentView.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            tabs.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            tabs.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            tabs.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -14),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        ])
        updateExplanations()
    }

    private func wallpaperView() -> NSView {
        let (view, stack) = tabContent()
        addPopupRow("Source", popup: sourcePopup, titles: WallpaperSource.allCases.map(\.title), action: #selector(sourceChanged(_:)), to: stack)
        addDescription(sourceDescription, to: stack)
        automaticButton.target = self
        automaticButton.action = #selector(automaticChanged(_:))
        automaticButton.state = settings.automaticUpdates ? .on : .off
        stack.addArrangedSubview(automaticButton)
        addPopupRow("Check for wallpaper", popup: intervalPopup, titles: UpdateInterval.allCases.map(\.title), action: #selector(intervalChanged(_:)), to: stack)
        addDescription("Automatic checks run while Daystar is open. Today changes only when NASA publishes a new image; Archive and Favorites rotate on each check. Manual updates are always available.", to: stack)
        addPopupRow("Image layout", popup: presentationPopup, titles: WallpaperPresentation.allCases.map(\.title), action: #selector(presentationChanged(_:)), to: stack)
        qualityButton.target = self
        qualityButton.action = #selector(qualityChanged(_:))
        qualityButton.state = settings.preferHighestResolution ? .on : .off
        stack.addArrangedSubview(qualityButton)
        addPopupRow("Videos / non-images", popup: nonImagePopup, titles: NonImageBehavior.allCases.map(\.title), action: #selector(nonImageChanged(_:)), to: stack)
        addDescription(nonImageDescription, to: stack)
        sourcePopup.selectItem(at: WallpaperSource.allCases.firstIndex(of: settings.wallpaperSource) ?? 0)
        intervalPopup.selectItem(at: UpdateInterval.allCases.firstIndex(of: settings.updateInterval) ?? 0)
        presentationPopup.selectItem(at: WallpaperPresentation.allCases.firstIndex(of: settings.wallpaperPresentation) ?? 0)
        nonImagePopup.selectItem(at: NonImageBehavior.allCases.firstIndex(of: settings.nonImageBehavior) ?? 0)
        return view
    }

    private func applicationView(cacheSizeBytes: Int64) -> NSView {
        let (view, stack) = tabContent()
        launchButton.target = self
        launchButton.action = #selector(launchChanged(_:))
        launchButton.state = launchAtLogin ? .on : .off
        stack.addArrangedSubview(launchButton)
        addDescription("No Daystar account is required. Settings, favorites, history, and your NASA key are stored locally on this Mac. Daystar requests imagery from NASA over the internet.", to: stack)
        stack.addArrangedSubview(sectionLabel("NASA API key"))
        apiKeyField.placeholderString = "Empty uses DEMO_KEY"
        apiKeyField.setAccessibilityLabel("NASA API key")
        apiKeyField.toolTip = "Paste your NASA API key, then choose Save Key. Leave empty to use DEMO_KEY."
        stack.addArrangedSubview(apiKeyField)
        apiKeyField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveAPIKey(_:))
        resetKeyButton.target = self
        resetKeyButton.action = #selector(resetAPIKey(_:))
        let keyActions = NSStackView(views: [
            saveKeyButton,
            resetKeyButton,
            NSButton(title: "Get a NASA Key…", target: self, action: #selector(openNASAKeys(_:)))
        ])
        keyActions.orientation = .horizontal
        keyActions.spacing = 8
        stack.addArrangedSubview(keyActions)
        addDescription("The built-in DEMO_KEY works without signing up but has lower request limits. An optional personal NASA key can increase those limits. Saving a key does not validate it or download an image.", to: stack)
        stack.addArrangedSubview(sectionLabel("Local image storage"))
        cacheLabel.stringValue = "Downloaded images: \(formattedBytes(cacheSizeBytes))"
        stack.addArrangedSubview(cacheLabel)
        clearCacheButton.target = self
        clearCacheButton.action = #selector(clearCache(_:))
        stack.addArrangedSubview(clearCacheButton)
        addDescription("Clearing downloaded images frees disk space without removing favorites, history, or settings. Images will be downloaded again when needed.", to: stack)
        return view
    }

    private func tabContent() -> (NSView, NSStackView) {
        let view = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20)
        ])
        return (view, stack)
    }

    private func addPopupRow(_ label: String, popup: NSPopUpButton, titles: [String], action: Selector, to stack: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
        popup.setAccessibilityLabel(label)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(labelField)
        row.addArrangedSubview(popup)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addDescription(_ text: String, to stack: NSStackView) {
        addDescription(NSTextField(wrappingLabelWithString: text), to: stack)
    }

    private func addDescription(_ label: NSTextField, to stack: NSStackView) {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func updateExplanations() {
        switch settings.wallpaperSource {
        case .today:
            sourceDescription.stringValue = "Today follows NASA’s Astronomy Picture of the Day (APOD). NASA usually publishes one new entry each day."
        case .archive:
            sourceDescription.stringValue = "Archive chooses a random image from NASA’s APOD collection, preferring images you have not seen."
        case .favorites:
            sourceDescription.stringValue = "Favorites rotates images you have starred in Daystar. Add favorites from the image details or library before selecting this source."
        }
        switch settings.nonImageBehavior {
        case .automatic:
            nonImageDescription.stringValue = "Automatic keeps your wallpaper when Today is a video or other non-image. Archive and Favorites skip non-images and choose another available image."
        case .skip:
            nonImageDescription.stringValue = "Skip non-images. Archive and Favorites try another image; Today leaves the current wallpaper in place if its entry is not an image."
        case .useThumbnail:
            nonImageDescription.stringValue = "Use a video’s thumbnail when NASA provides one. Other non-images cannot be used as wallpapers. Thumbnails may have lower resolution."
        case .keepCurrent:
            nonImageDescription.stringValue = "Keep the current desktop wallpaper when Today is not an image. Archive and Favorites still select an available image rather than a non-image."
        }
        intervalPopup.isEnabled = settings.automaticUpdates
    }

    private func emitSettings() {
        onSettingsChanged(settings)
        updateExplanations()
        setStatus("Wallpaper settings saved and applied.")
    }

    private func setStatus(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
