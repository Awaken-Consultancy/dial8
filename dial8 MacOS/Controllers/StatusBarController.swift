import SwiftUI
import AppKit

class StatusBarController: NSObject, ObservableObject {
    private var statusBar: NSStatusBar?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    @ObservedObject var audioManager: AudioManager

    private var settingsItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var settingsWindowController: NSWindowController?

    private let clipboardTextInsertion = ClipboardTextInsertion()

    private var appDelegate: AppDelegate? {
        return NSApp.delegate as? AppDelegate
    }

    init(audioManager: AudioManager) {
        self.audioManager = audioManager
        super.init()
        DispatchQueue.main.async { [weak self] in
            self?.setupStatusBar()
        }
    }

    private func setupStatusBar() {
        statusBar = NSStatusBar.system
        statusItem = statusBar?.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        setupStatusBarButton()
        setupMenu()
    }

    private func setupStatusBarButton() {
        if let statusBarButton = statusItem?.button {
            // Load the custom icon
            if let icon = NSImage(named: "StatusBarIcon") {
                // Ensure it's treated as a template image
                icon.isTemplate = true
                // Set the icon size to 16x16 for proper status bar fit
                icon.size = NSSize(width: 16, height: 16)
                statusBarButton.image = icon
            }

            // Set action to show menu when clicked
            statusBarButton.action = #selector(handleStatusBarClick(_:))
            statusBarButton.target = self

            // Enable click detection
            statusBarButton.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupMenu() {
        // Menu will be built dynamically on click
        statusItem?.menu = nil
    }

    @objc func handleStatusBarClick(_ sender: Any?) {
        // Show the main menu on any click
        showMainMenu()
    }

    // MARK: - Menu Building

    private func showMainMenu() {
        let menu = buildMainMenu()

        // Show the menu
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)

        // Remove the menu after showing to restore normal click behavior
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    private func buildMainMenu() -> NSMenu {
        let menu = NSMenu()

        // SECTION 1: Recent Transcripts
        let recentTranscriptsHeader = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        recentTranscriptsHeader.isEnabled = false
        menu.addItem(recentTranscriptsHeader)

        let transcripts = TranscriptionHistoryManager.shared.transcriptionHistory

        if transcripts.isEmpty {
            let emptyItem = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for (index, item) in transcripts.prefix(5).enumerated() {
                let truncatedText = truncateText(item.text, maxLength: 50)
                let menuItem = NSMenuItem(
                    title: "\(item.formattedDate): \(truncatedText)",
                    action: #selector(insertTranscript(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.tag = index
                menuItem.representedObject = item
                menu.addItem(menuItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // SECTION 2: Microphone Selection Submenu
        let microphoneItem = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        microphoneItem.submenu = buildMicrophoneSubmenu()
        menu.addItem(microphoneItem)

        menu.addItem(NSMenuItem.separator())

        // SECTION 3: Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // SECTION 4: Quit
        let quitItem = NSMenuItem(title: "Quit Dial8", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func buildMicrophoneSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let deviceService = AudioDeviceEnumerationService.shared
        let devices = deviceService.inputDevices
        let selectedUID = deviceService.selectedDeviceUID

        // Add "System Default" option
        let defaultItem = NSMenuItem(
            title: "System Default",
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.representedObject = nil as String?
        defaultItem.state = (selectedUID == nil) ? .on : .off
        submenu.addItem(defaultItem)

        submenu.addItem(NSMenuItem.separator())

        // Add all available input devices
        for device in devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectMicrophone(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uid
            item.state = (selectedUID == device.uid) ? .on : .off
            submenu.addItem(item)
        }

        return submenu
    }

    // MARK: - Menu Actions

    private func truncateText(_ text: String, maxLength: Int) -> String {
        // Remove newlines and normalize whitespace
        let cleanedText = text.components(separatedBy: .newlines).joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")

        if cleanedText.count <= maxLength {
            return cleanedText
        }
        let endIndex = cleanedText.index(cleanedText.startIndex, offsetBy: maxLength)
        return String(cleanedText[..<endIndex]) + "..."
    }

    @objc private func insertTranscript(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TranscriptionHistoryItem else { return }

        // Use ClipboardTextInsertion to paste the text directly
        _ = clipboardTextInsertion.insertText(item.text, preserveClipboard: true)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String
        AudioDeviceEnumerationService.shared.selectDevice(uid: uid)
    }

    @objc private func openSettingsWindow() {
        Task { @MainActor in
            // Check if settings window already exists
            if let existingWindow = settingsWindow {
                // Window exists, bring it to front
                existingWindow.makeKeyAndOrderFront(nil)
                existingWindow.orderFrontRegardless()

                // If window is minimized, deminiaturize it
                if existingWindow.isMiniaturized {
                    existingWindow.deminiaturize(nil)
                }

                // Ensure window is visible
                if !existingWindow.isVisible {
                    existingWindow.orderFront(nil)
                }

                // Force app activation with more aggressive settings
                NSApp.activate(ignoringOtherApps: true)
                NSApp.arrangeInFront(nil)
                existingWindow.level = .floating
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    existingWindow.level = .normal
                }

                return
            }

            // Create new window only if it doesn't exist
            let windowManager = WindowManager()
            let contentView = ContentView()
                .environmentObject(windowManager)
                .environmentObject(self.audioManager)
            let hostingController = NSHostingController(rootView: contentView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = ""
            window.setContentSize(NSSize(width: 1000, height: 700))
            window.minSize = NSSize(width: 800, height: 500)
            window.center()

            // Configure window style
            window.backgroundColor = NSColor.windowBackgroundColor
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden

            // Set delegate to handle window closing
            window.delegate = self

            // Store reference to the window
            settingsWindow = window

            // Create window controller to keep window alive
            let windowController = NSWindowController(window: window)
            settingsWindowController = windowController

            windowController.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.arrangeInFront(nil)

            // Temporarily set floating level to ensure it comes to front
            window.level = .floating
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                window.level = .normal
            }
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NSWindowDelegate
extension StatusBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Clear the window reference when it closes
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
            settingsWindowController = nil
        }
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Allow the window to close
        return true
    }
}
