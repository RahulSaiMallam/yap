import AVFoundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@main
struct YapApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if !appState.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    ContentView()
                }
            }
            .frame(minWidth: 520, idealWidth: 600, maxWidth: 900)
            .frame(minHeight: 480, idealHeight: 720, maxHeight: 1100)
            .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    if let delegate = NSApplication.shared.delegate as? AppDelegate {
                        delegate.showMainWindow()
                    }
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "openMainWindow"))
    }

    init() {
        _ = ShortcutManager.shared
        _ = MicrophoneService.shared
        WhisperModelManager.shared.ensureDefaultModelPresent()
    }
}

extension YapApp {
    static func startTranscriptionQueue() {
        Task { @MainActor in
            TranscriptionQueue.shared.startProcessingQueue()
        }
    }
}

class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            AppPreferences.shared.hasCompletedOnboarding = hasCompletedOnboarding
        }
    }

    init() {
        var onboarding = AppPreferences.shared.hasCompletedOnboarding
        #if DEBUG
        if let force = DevConfig.shared.forceShowOnboarding {
            onboarding = !force
        }
        #endif
        self.hasCompletedOnboarding = onboarding
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var languageSubmenu: NSMenu?
    private var microphoneService = MicrophoneService.shared
    private var microphoneObserver: AnyCancellable?
    
    func applicationDidFinishLaunching(_ notification: Notification) {

        setupStatusBarItem()

        if let window = NSApplication.shared.windows.first {
            self.mainWindow = window
            window.delegate = self

            window.minSize = NSSize(width: 520, height: 480)
            window.maxSize = NSSize(width: 1100, height: 1100)

            // SwiftUI restores the saved window frame from UserDefaults. On
            // a multi-monitor setup the saved frame can reference a screen
            // that's no longer connected, leaving the window at an
            // off-screen position (e.g. x=-1185) where the user can't find
            // it. Re-center on the active screen if no current screen
            // intersects the saved frame.
            ensureWindowOnscreen(window)

            // LSUIElement keeps the app in .accessory until something
            // explicitly asks for the regular policy. Without this hop the
            // SwiftUI main window can launch into a hidden state — the
            // process is alive, the window object exists, but it never
            // makes it to a visible screen. Surfacing it on launch matches
            // what users expect when they double-click the app icon or
            // open it from Spotlight.
            showMainWindow()
        }

        YapApp.startTranscriptionQueue()
        observeMicrophoneChanges()
    }

    /// Called by AppKit when the user reopens the app while it's still
    /// running (Spotlight, double-click in Finder, Cmd+Tab activation
    /// when the window had been closed). Default behavior for an
    /// LSUIElement app is "do nothing", which leaves the user with no
    /// way to bring the window back short of clicking the menu-bar
    /// icon. Restore the main window instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    private func ensureWindowOnscreen(_ window: NSWindow) {
        let frame = window.frame
        let intersectsAnyScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(frame)
        }
        guard !intersectsAnyScreen else { return }

        let target = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        guard let target else { return }
        let centered = NSRect(
            x: target.midX - frame.width / 2,
            y: target.midY - frame.height / 2,
            width: frame.width,
            height: frame.height
        )
        window.setFrame(centered, display: true)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard isAudioFile(url) else {
            return false
        }

        queueAudioURLs([url])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let audioURLs = filenames
            .map { URL(fileURLWithPath: $0) }
            .filter { isAudioFile($0) }

        sender.reply(toOpenOrPrint: audioURLs.isEmpty ? .failure : .success)
        queueAudioURLs(audioURLs)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let audioURLs = urls.filter { isAudioFile($0) }
        queueAudioURLs(audioURLs)
    }

    private func queueAudioURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            showMainWindow()

            for url in urls {
                await TranscriptionQueue.shared.addFileToQueue(url: url)
            }
        }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType.conforms(to: .audio)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }
    
    private func observeMicrophoneChanges() {
        microphoneObserver = microphoneService.$availableMicrophones
            .sink { [weak self] _ in
                self?.updateStatusBarMenu()
            }
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            if let iconImage = NSImage(named: "tray_icon") {
                iconImage.size = NSSize(width: 48, height: 48)
                iconImage.isTemplate = true
                button.image = iconImage
            } else {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yap")
            }
            
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
        }
        
        updateStatusBarMenu()
    }
    
    private func updateStatusBarMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Open Yap", action: #selector(openApp), keyEquivalent: "o"))
        
        let transcriptionLanguageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageSubmenu = NSMenu()
        
        // Add language options
        for languageCode in LanguageUtil.availableLanguages {
            let languageName = LanguageUtil.languageNames[languageCode] ?? languageCode
            let languageItem = NSMenuItem(title: languageName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            languageItem.target = self
            languageItem.representedObject = languageCode
            languageItem.state = (AppPreferences.shared.whisperLanguage == languageCode) ? .on : .off
            languageSubmenu?.addItem(languageItem)
        }
        
        transcriptionLanguageItem.submenu = languageSubmenu
        menu.addItem(transcriptionLanguageItem)
        
        // Listen for language preference changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languagePreferenceChanged),
            name: .appPreferencesLanguageChanged,
            object: nil
        )
        
        menu.addItem(NSMenuItem.separator())
        
        let microphoneMenu = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        
        let microphones = microphoneService.availableMicrophones
        let currentMic = microphoneService.currentMicrophone
        
        if microphones.isEmpty {
            let noDeviceItem = NSMenuItem(title: "No microphones available", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            submenu.addItem(noDeviceItem)
        } else {
            let builtInMicrophones = microphones.filter { $0.isBuiltIn }
            let externalMicrophones = microphones.filter { !$0.isBuiltIn }
            
            for microphone in builtInMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                
                if let current = currentMic, current.id == microphone.id {
                    item.state = .on
                }
                
                submenu.addItem(item)
            }
            
            if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                submenu.addItem(NSMenuItem.separator())
            }
            
            for microphone in externalMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                
                if let current = currentMic, current.id == microphone.id {
                    item.state = .on
                }
                
                submenu.addItem(item)
            }
        }
        
        microphoneMenu.submenu = submenu
        menu.addItem(microphoneMenu)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }
    
    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? MicrophoneService.AudioDevice else { return }
        microphoneService.selectMicrophone(device)
        updateStatusBarMenu()
    }
    
    @objc private func statusBarButtonClicked(_ sender: Any) {
        statusItem?.button?.performClick(nil)
    }
    
    @objc private func openApp() {
        showMainWindow()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let languageCode = sender.representedObject as? String else { return }
        
        // Update preferences
        AppPreferences.shared.whisperLanguage = languageCode
        
        // Update menu item states
        if let submenu = sender.menu {
            for item in submenu.items {
                item.state = .off
            }
            sender.state = .on
        }
    }
    
    @objc private func languagePreferenceChanged() {
        updateLanguageMenuSelection()
    }
    
    private func updateLanguageMenuSelection() {
        guard let languageSubmenu = languageSubmenu else { return }
        
        let currentLanguage = AppPreferences.shared.whisperLanguage
        
        for item in languageSubmenu.items {
            if let languageCode = item.representedObject as? String {
                item.state = (languageCode == currentLanguage) ? .on : .off
            }
        }
    }
    
    func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        
        if let window = mainWindow {
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else if let url = URL(string: "yap://openMainWindow") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
