import AppKit
import APODWallpaperCore
import ServiceManagement
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settingsStore: APODSettingsStore
    private let coordinator: WallpaperCoordinator
    private let loginItemManager = LoginItemManager()
    private var statusItem: NSStatusItem!
    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var launchAtLoginError: Error?
    private var onboardingController: OnboardingWindowController?
    private var detailController: APODDetailWindowController?
    private var recentController: RecentWindowController?
    private var settingsController: SettingsWindowController?
    private var menuActivityView: WallpaperActivityView?
    private var activityPanel: NSPanel?
    private var panelActivityView: WallpaperActivityView?
    private var wasUpdating = false

    override init() {
        let settingsStore = APODSettingsStore()
        let settings = settingsStore.load()
        let store: APODStore
        do {
            store = try APODStore()
        } catch {
            fatalError("Could not initialize APOD storage: \(error.localizedDescription)")
        }

        self.settingsStore = settingsStore
        let apiKey = settingsStore.nasaAPIKey ?? "DEMO_KEY"
        self.coordinator = WallpaperCoordinator(
            client: NASAAPODClient(apiKey: apiKey),
            store: store,
            wallpaper: WorkspaceWallpaperApplier(),
            settings: settings
        )

        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Daystar"
        )
        statusItem.button?.toolTip = "Daystar — astronomy on your desktop"
        coordinator.onChange = { [weak self] in self?.updateActivity() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationMenu()
        coordinator.restoreCachedWallpaper()
        rebuildMenu()

        guard settingsStore.onboardingComplete else {
            showOnboarding()
            return
        }
        startAutomaticUpdates()
        refresh(force: false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if settingsStore.onboardingComplete {
                openRecent(nil)
            } else {
                showOnboarding()
            }
        }
        return true
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Daystar")
        applicationMenu.addItem(menuItem("About Daystar", action: #selector(showAbout(_:))))
        applicationMenu.addItem(menuItem("Library — Recents & Favorites…", action: #selector(openRecent(_:))))
        applicationMenu.addItem(menuItem("Settings…", action: #selector(openSettings(_:))))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem("Quit Daystar", action: #selector(quit(_:))))
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        coordinator.cancelUpdate()
        refreshTask?.cancel()
    }

    @objc private func nextWallpaper(_ sender: Any?) {
        guard !coordinator.isUpdating else { return }
        showActivityPanel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await coordinator.nextWallpaper()
            rebuildMenu()
        }
    }

    @objc private func previousWallpaper(_ sender: Any?) {
        guard !coordinator.isUpdating, coordinator.canGoPrevious else { return }
        showActivityPanel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await coordinator.previousWallpaper()
            rebuildMenu()
        }
    }

    @objc private func setWallpaperNow(_ sender: Any?) {
        guard !coordinator.isUpdating else { return }
        showActivityPanel()
        if coordinator.latestAPOD == nil {
            refresh(force: true)
        } else {
            reapplyCurrent()
        }
    }
    @objc private func favoriteCurrent(_ sender: Any?) {
        _ = coordinator.toggleCurrentFavorite()
        rebuildMenu()
    }

    @objc private func openTodaysAPOD(_ sender: Any?) {
        guard let url = coordinator.latestAPOD?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func readExplanation(_ sender: Any?) {
        guard let apod = coordinator.latestAPOD else { return }
        showDetails(apod: apod, imageURL: coordinator.currentImageURL)
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let source = WallpaperSource(rawValue: rawValue) else {
            return
        }
        guard !coordinator.isUpdating else { rebuildMenu(); return }
        coordinator.wallpaperSource = source
        persistSettings()
        startAutomaticUpdates()
        refresh(force: true)
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber,
              let interval = UpdateInterval(rawValue: value.doubleValue) else {
            return
        }
        coordinator.updateInterval = interval
        persistSettings()
        startAutomaticUpdates()
        rebuildMenu()
    }

    @objc private func selectNonImageBehavior(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let behavior = NonImageBehavior(rawValue: rawValue) else {
            return
        }
        coordinator.nonImageBehavior = behavior
        persistSettings()
        rebuildMenu()
    }

    @objc private func toggleAutomaticUpdates(_ sender: NSMenuItem) {
        coordinator.automaticUpdates.toggle()
        persistSettings()
        startAutomaticUpdates()
        rebuildMenu()
    }

    @objc private func selectPresentation(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let presentation = WallpaperPresentation(rawValue: rawValue) else {
            return
        }
        coordinator.wallpaperPresentation = presentation
        persistSettings()
        reapplyCurrent()
    }

    @objc private func toggleHighestResolution(_ sender: NSMenuItem) {
        coordinator.preferHighestResolution.toggle()
        persistSettings()
        reapplyCurrent()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if let message = setLaunchAtLogin(!loginItemManager.isEnabled) {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = message
            alert.runModal()
        }
    }

    @objc private func openRecent(_ sender: Any?) {
        if recentController == nil {
            recentController = RecentWindowController(
                coordinator: coordinator,
                showDetails: { [weak self] record in
                    self?.showDetails(apod: record.apod, imageURL: record.cachedImagePath)
                }
            )
        }
        recentController?.showWindow(nil)
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsController = SettingsWindowController(
            settings: coordinator.settings,
            launchAtLogin: loginItemManager.isEnabled,
            cacheSizeBytes: coordinator.cacheSizeBytes(),
            apiKey: settingsStore.nasaAPIKey,
            onSettingsChanged: { [weak self] settings in
                self?.apply(settings: settings)
            },
            onLaunchAtLoginChanged: { [weak self] enabled in
                self?.setLaunchAtLogin(enabled)
            },
            onClearCache: { [weak self] in
                guard let self else { return .success(0) }
                return coordinator.clearImageCache()
            },
            onAPIKeyChanged: { [weak self] key in
                guard let self else { return }
                settingsStore.nasaAPIKey = key
                coordinator.setClient(NASAAPODClient(apiKey: key ?? "DEMO_KEY"))
            }
        )
        settingsController?.updateState(isUpdating: coordinator.isUpdating)
        settingsController?.showWindow(nil)
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    private func refresh(force: Bool) {
        guard !coordinator.isUpdating else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await coordinator.refresh(force: force)
            rebuildMenu()
        }
    }

    private func reapplyCurrent() {
        guard coordinator.latestAPOD != nil else {
            rebuildMenu()
            return
        }
        guard !coordinator.isUpdating else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await coordinator.reapplyCurrent()
            rebuildMenu()
        }
    }

    private func startAutomaticUpdates() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard coordinator.automaticUpdates else {
            return
        }
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: coordinator.updateInterval.rawValue,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh(force: false)
            }
        }
    }

    private func apply(settings: APODSettings, refreshWallpaper: Bool = true) {
        let sourceChanged = coordinator.wallpaperSource != settings.wallpaperSource
        let presentationChanged = coordinator.wallpaperPresentation != settings.wallpaperPresentation
            || coordinator.preferHighestResolution != settings.preferHighestResolution
        coordinator.wallpaperSource = settings.wallpaperSource
        coordinator.updateInterval = settings.updateInterval
        coordinator.nonImageBehavior = settings.nonImageBehavior
        coordinator.preferHighestResolution = settings.preferHighestResolution
        coordinator.wallpaperPresentation = settings.wallpaperPresentation
        coordinator.automaticUpdates = settings.automaticUpdates
        persistSettings()
        startAutomaticUpdates()
        rebuildMenu()
        if refreshWallpaper && sourceChanged {
            refresh(force: true)
        } else if refreshWallpaper && presentationChanged {
            reapplyCurrent()
        }
    }

    @discardableResult
    private func setLaunchAtLogin(_ enabled: Bool) -> String? {
        launchAtLoginError = nil
        do {
            if loginItemManager.isEnabled != enabled {
                try loginItemManager.setEnabled(enabled)
            }
            settingsStore.launchAtLogin = enabled
        } catch {
            launchAtLoginError = error
        }
        rebuildMenu()
        return launchAtLoginError?.localizedDescription
    }

    private func persistSettings() {
        settingsStore.save(coordinator.settings)
    }

    private func showOnboarding() {
        onboardingController = OnboardingWindowController(
            settings: coordinator.settings,
            launchAtLogin: settingsStore.launchAtLogin,
            onStart: { [weak self] settings, launchAtLogin in
                self?.finishOnboarding(settings: settings, launchAtLogin: launchAtLogin)
            }
        )
        onboardingController?.showWindow(nil)
    }

    private func finishOnboarding(settings: APODSettings, launchAtLogin: Bool) -> String? {
        if let error = setLaunchAtLogin(launchAtLogin) { return error }
        settingsStore.onboardingComplete = true
        apply(settings: settings, refreshWallpaper: false)
        startAutomaticUpdates()
        showActivityPanel()
        refresh(force: true)
        return nil
    }

    private func showDetails(apod: APOD, imageURL: URL?) {
        detailController = APODDetailWindowController(
            apod: apod,
            imageURL: imageURL,
            coordinator: coordinator
        )
        detailController?.showWindow(nil)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.delegate = self
        let heading = NSMenuItem(title: "Daystar", action: nil, keyEquivalent: "")
        let activity = WallpaperActivityView(cancelTarget: self, action: #selector(cancelDownload(_:)))
        activity.update(
            message: activityMessage,
            fraction: coordinator.downloadFraction,
            busy: coordinator.isUpdating,
            error: coordinator.lastError != nil
        )
        heading.view = activity
        menuActivityView = activity
        menu.addItem(heading)

        if let apod = coordinator.latestAPOD {
            let title = NSMenuItem(title: apod.title, action: nil, keyEquivalent: "")
            title.isEnabled = false
            if let imageURL = coordinator.currentImageURL,
               let image = NSImage(contentsOf: imageURL) {
                image.size = NSSize(width: 80, height: 50)
                title.image = image
            }
            menu.addItem(title)

            let date = NSMenuItem(title: formattedDate(apod.date), action: nil, keyEquivalent: "")
            date.isEnabled = false
            menu.addItem(date)

            if let copyright = apod.copyright, !copyright.isEmpty {
                let credit = NSMenuItem(title: copyright, action: nil, keyEquivalent: "")
                credit.isEnabled = false
                menu.addItem(credit)
            }
        } else {
            let status = NSMenuItem(title: "No APOD loaded yet", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        if let emptyStateMessage = coordinator.emptyStateMessage {
            let status = NSMenuItem(title: emptyStateMessage, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        } else if let error = coordinator.lastError {
            let status = NSMenuItem(
                title: "Update failed: \(error.localizedDescription)",
                action: nil,
                keyEquivalent: ""
            )
            status.isEnabled = false
            menu.addItem(status)
        }

        menu.addItem(.separator())
        let setItem = menuItem("Set Wallpaper Now", action: #selector(setWallpaperNow(_:)))
        setItem.isEnabled = !coordinator.isUpdating
        menu.addItem(setItem)
        let nextItem = menuItem("Next Wallpaper", action: #selector(nextWallpaper(_:)))
        nextItem.isEnabled = !coordinator.isUpdating
        menu.addItem(nextItem)
        let previousItem = menuItem("Previous Wallpaper", action: #selector(previousWallpaper(_:)))
        previousItem.isEnabled = !coordinator.isUpdating && coordinator.canGoPrevious
        menu.addItem(previousItem)

        let favoriteTitle = coordinator.isCurrentFavorite ? "Unfavorite" : "Favorite"
        let favoriteItem = menuItem(favoriteTitle, action: #selector(favoriteCurrent(_:)))
        favoriteItem.isEnabled = coordinator.latestAPOD != nil
        menu.addItem(favoriteItem)

        let viewItem = menuItem("View APOD", action: #selector(openTodaysAPOD(_:)))
        viewItem.isEnabled = coordinator.latestAPOD != nil
        menu.addItem(viewItem)
        let explanationItem = menuItem("Read Explanation", action: #selector(readExplanation(_:)))
        explanationItem.isEnabled = coordinator.latestAPOD != nil
        menu.addItem(explanationItem)

        menu.addItem(.separator())
        let sourceItem = NSMenuItem(title: "Wallpaper Source", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu()
        menu.addItem(sourceItem)
        let intervalItem = NSMenuItem(title: "Update", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu()
        menu.addItem(intervalItem)
        let automaticItem = menuItem(
            "Update Automatically",
            action: #selector(toggleAutomaticUpdates(_:))
        )
        automaticItem.state = coordinator.automaticUpdates ? .on : .off
        menu.addItem(automaticItem)

        menu.addItem(.separator())
        let recentItem = menuItem("Library — Recents & Favorites…", action: #selector(openRecent(_:)))
        menu.addItem(recentItem)
        let settingsItem = menuItem("Settings…", action: #selector(openSettings(_:)))
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let loginItem = menuItem("Launch at Login", action: #selector(toggleLaunchAtLogin(_:)))
        loginItem.state = loginItemManager.isEnabled ? .on : .off
        loginItem.toolTip = launchAtLoginError?.localizedDescription
        menu.addItem(loginItem)
        menu.addItem(menuItem("About Daystar", action: #selector(showAbout(_:))))
        menu.addItem(menuItem("Quit Daystar", action: #selector(quit(_:))))

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuActivityView?.update(message: activityMessage, fraction: coordinator.downloadFraction,
                                 busy: coordinator.isUpdating, error: coordinator.lastError != nil)
    }

    private var activityMessage: String {
        coordinator.lastError?.localizedDescription
            ?? coordinator.emptyStateMessage
            ?? coordinator.operationMessage
    }

    private func updateActivity() {
        let busy = coordinator.isUpdating
        menuActivityView?.update(message: activityMessage, fraction: coordinator.downloadFraction,
                                 busy: busy, error: coordinator.lastError != nil)
        panelActivityView?.update(message: activityMessage, fraction: coordinator.downloadFraction,
                                  busy: busy, error: coordinator.lastError != nil)
        statusItem.button?.toolTip = "Daystar — \(activityMessage)"
        if busy != wasUpdating {
            statusItem.button?.wantsLayer = true
            if busy && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let twinkle = CAKeyframeAnimation(keyPath: "opacity")
                twinkle.values = [1, 0.35, 1, 0.65, 1]
                twinkle.duration = 1.6
                twinkle.repeatCount = .infinity
                statusItem.button?.layer?.add(twinkle, forKey: "daystar.twinkle")
            } else {
                statusItem.button?.layer?.removeAnimation(forKey: "daystar.twinkle")
            }
            wasUpdating = busy
            rebuildMenu()
        } else if !busy {
            rebuildMenu()
        }
        recentController?.updateState()
        detailController?.updateState()
        settingsController?.updateState(isUpdating: busy)
    }

    private func showActivityPanel() {
        if activityPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 350, height: 108),
                styleMask: [.titled, .closable, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.title = "Daystar"
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let view = WallpaperActivityView(cancelTarget: self, action: #selector(cancelDownload(_:)))
            panel.contentView = view
            panelActivityView = view
            activityPanel = panel
            if let screen = statusItem.button?.window?.screen ?? NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 374, y: frame.maxY - 16))
            }
        }
        panelActivityView?.update(message: "Preparing your wallpaper…", fraction: nil, busy: true, error: false)
        activityPanel?.orderFrontRegardless()
    }

    @objc private func cancelDownload(_ sender: Any?) {
        coordinator.cancelUpdate()
        refreshTask?.cancel()
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Daystar",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0",
            .credits: NSAttributedString(string: "A little more universe on your desktop.\nAstronomy imagery and stories from NASA APOD.\nFavorites, history, and images stay on this Mac.")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func sourceMenu() -> NSMenu {
        let menu = NSMenu()
        for source in WallpaperSource.allCases {
            let item = NSMenuItem(
                title: source.title,
                action: #selector(selectSource(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = !coordinator.isUpdating
            item.representedObject = source.rawValue
            item.state = coordinator.wallpaperSource == source ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func intervalMenu() -> NSMenu {
        let menu = NSMenu()
        for interval in UpdateInterval.allCases {
            let item = NSMenuItem(
                title: interval.title,
                action: #selector(selectInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: interval.rawValue)
            item.state = coordinator.updateInterval == interval ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let presentation = NSMenuItem(title: "Presentation", action: nil, keyEquivalent: "")
        presentation.submenu = presentationMenu()
        menu.addItem(presentation)
        let quality = menuItem(
            "Prefer highest resolution",
            action: #selector(toggleHighestResolution(_:))
        )
        quality.state = coordinator.preferHighestResolution ? .on : .off
        quality.isEnabled = !coordinator.isUpdating
        menu.addItem(quality)
        let nonImage = NSMenuItem(title: "Non-image APODs", action: nil, keyEquivalent: "")
        nonImage.submenu = nonImageMenu()
        menu.addItem(nonImage)
        return menu
    }

    private func nonImageMenu() -> NSMenu {
        let menu = NSMenu()
        for behavior in NonImageBehavior.allCases {
            let item = NSMenuItem(
                title: behavior.title,
                action: #selector(selectNonImageBehavior(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = !coordinator.isUpdating
            item.representedObject = behavior.rawValue
            item.state = coordinator.nonImageBehavior == behavior ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func presentationMenu() -> NSMenu {
        let menu = NSMenu()
        for presentation in WallpaperPresentation.allCases {
            let item = NSMenuItem(
                title: presentation.title,
                action: #selector(selectPresentation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = !coordinator.isUpdating
            item.representedObject = presentation.rawValue
            item.state = coordinator.wallpaperPresentation == presentation ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        switch action {
        case #selector(openSettings(_:)): item.keyEquivalent = ","
        case #selector(openRecent(_:)): item.keyEquivalent = "l"
        case #selector(quit(_:)): item.keyEquivalent = "q"
        case #selector(nextWallpaper(_:)): item.keyEquivalent = "]"
        case #selector(previousWallpaper(_:)): item.keyEquivalent = "["
        default: break
        }
        return item
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: "\(value)T00:00:00Z") else {
            return value
        }
        return DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .none)
    }
}

@MainActor
private final class WorkspaceWallpaperApplier: WallpaperApplying, @unchecked Sendable {
    func apply(imageURL: URL, presentation: WallpaperPresentation) throws {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        switch presentation {
        case .fill:
            options[.imageScaling] = NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue)
            options[.allowClipping] = NSNumber(value: true)
        case .fit:
            options[.imageScaling] = NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue)
            options[.allowClipping] = NSNumber(value: false)
        case .center:
            options[.imageScaling] = NSNumber(value: NSImageScaling.scaleNone.rawValue)
        case .stretch:
            options[.imageScaling] = NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue)
        }

        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(
                imageURL,
                for: screen,
                options: options
            )
        }
    }
}

private struct LoginItemManager {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
