import AppKit
import APODWallpaperCore

@MainActor
final class OnboardingWindowController: NSWindowController {
    private var settings: APODSettings
    private let launchAtLogin: Bool
    private let onStart: (APODSettings, Bool) -> String?
    private let sourcePopup = NSPopUpButton()
    private let intervalPopup = NSPopUpButton()
    private let qualityButton = NSButton(checkboxWithTitle: "Prefer highest-resolution images", target: nil, action: nil)
    private let automaticButton = NSButton(checkboxWithTitle: "Update wallpaper automatically", target: nil, action: nil)
    private let launchButton = NSButton(checkboxWithTitle: "Launch Daystar at login", target: nil, action: nil)
    private let sourceDescription = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "You can change these choices and add an optional NASA API key in Settings.")

    init(
        settings: APODSettings,
        launchAtLogin: Bool,
        onStart: @escaping (APODSettings, Bool) -> String?
    ) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        self.onStart = onStart

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Daystar"
        window.contentMinSize = NSSize(width: 560, height: 620)
        super.init(window: window)
        buildView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func start(_ sender: Any?) {
        guard let source = WallpaperSource.allCases[safe: sourcePopup.indexOfSelectedItem],
              let interval = UpdateInterval.allCases[safe: intervalPopup.indexOfSelectedItem] else {
            return
        }
        settings.wallpaperSource = source
        settings.updateInterval = interval
        settings.preferHighestResolution = qualityButton.state == .on
        settings.automaticUpdates = automaticButton.state == .on
        if let error = onStart(settings, launchButton.state == .on) {
            launchButton.state = launchAtLogin ? .on : .off
            statusLabel.stringValue = "Could not start: \(error) Launch at login was restored to its previous setting. You can try again with that setting."
            statusLabel.textColor = .systemRed
            return
        }
        close()
    }

    @objc private func sourceChanged(_ sender: Any?) {
        updateSourceDescription()
    }

    @objc private func automaticChanged(_ sender: Any?) {
        intervalPopup.isEnabled = automaticButton.state == .on
    }

    private func buildView() {
        guard let contentView = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -26)
        ])

        let title = NSTextField(labelWithString: "Welcome to Daystar")
        title.font = .boldSystemFont(ofSize: 24)
        stack.addArrangedSubview(title)
        addDescription("A new view of the universe on your desktop. Daystar brings NASA’s Astronomy Picture of the Day (APOD) to your Mac’s wallpaper.", to: stack)
        addDescription("No Daystar account is needed. Your settings, favorites, and history stay on this Mac. An internet connection is needed to download NASA imagery.", to: stack)

        addPopupRow("Wallpaper source", popup: sourcePopup, titles: WallpaperSource.allCases.map(\.title), to: stack)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged(_:))
        addDescription(sourceDescription, to: stack)
        automaticButton.state = settings.automaticUpdates ? .on : .off
        automaticButton.target = self
        automaticButton.action = #selector(automaticChanged(_:))
        stack.addArrangedSubview(automaticButton)
        addPopupRow("Check for wallpaper", popup: intervalPopup, titles: UpdateInterval.allCases.map(\.title), to: stack)
        addDescription("Automatic checks run while Daystar is open. Today follows NASA’s daily entry; Archive and Favorites rotate on each check. Videos are handled using your non-image preference in Settings.", to: stack)
        qualityButton.state = settings.preferHighestResolution ? .on : .off
        stack.addArrangedSubview(qualityButton)
        launchButton.state = launchAtLogin ? .on : .off
        stack.addArrangedSubview(launchButton)
        addDescription(statusLabel, to: stack)
        statusLabel.setAccessibilityIdentifier("onboardingStatus")

        let startButton = NSButton(title: "Start Daystar", target: self, action: #selector(start(_:)))
        startButton.keyEquivalent = "\r"
        startButton.bezelStyle = .rounded
        startButton.toolTip = "Save these settings and request your first wallpaper."
        stack.addArrangedSubview(startButton)

        sourcePopup.selectItem(at: WallpaperSource.allCases.firstIndex(of: settings.wallpaperSource) ?? 0)
        intervalPopup.selectItem(at: UpdateInterval.allCases.firstIndex(of: settings.updateInterval) ?? 0)
        automaticChanged(nil)
        updateSourceDescription()
    }

    private func addPopupRow(_ label: String, popup: NSPopUpButton, titles: [String], to stack: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.widthAnchor.constraint(equalToConstant: 145).isActive = true
        popup.addItems(withTitles: titles)
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
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 0
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func updateSourceDescription() {
        guard let source = WallpaperSource.allCases[safe: sourcePopup.indexOfSelectedItem] else { return }
        switch source {
        case .today:
            sourceDescription.stringValue = "Use NASA’s latest daily entry. With Automatic non-image handling, a video day keeps your existing wallpaper."
        case .archive:
            sourceDescription.stringValue = "Explore random images from NASA’s APOD archive, preferring images you have not seen. A good place to start."
        case .favorites:
            sourceDescription.stringValue = "Rotate the images you have starred in Daystar. If you have no favorites yet, start with Archive and add some in the library."
        }
    }
}
