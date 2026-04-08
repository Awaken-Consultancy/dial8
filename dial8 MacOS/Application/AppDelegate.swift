import SwiftUI
import os

#if os(iOS)
import UIKit
#elseif os(macOS)
import Cocoa
import AVFoundation // Import AVFoundation for macOS
import Sparkle      // Import Sparkle for macOS
#endif

// Add this extension at the top of your file
extension Notification.Name {
    static let appWillResignActive = Notification.Name("AppWillResignActive") // Add custom notification
}

// Add extension for UserDefaults
extension UserDefaults {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "enableAutoPunctuation": true
        ])
    }
}

#if os(iOS)
class AppDelegate: UIResponder, UIApplicationDelegate {
    private let logger = Logger(subsystem: "com.dial8", category: "AppDelegate")
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    // MARK: UISceneSession Lifecycle
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if url.scheme == "com.dial8.oauth" {
            // OAuth handling removed
            return true
        }
        return false
    }
}
#elseif os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let logger = Logger(subsystem: "com.dial8", category: "AppDelegate")

    var updaterController: SPUStandardUpdaterController!
    private var isCheckingForUpdates = false

    // Add these properties for handling text overlay
    private var hudController: HUDMainController?
    private var textOverlayController: SelectedTextOverlayController?
    
    // Properties for window management
    private var onboardingWindow: NSWindow?
    private var onboardingWindowController: NSWindowController?

    // Add these at the top of your AppDelegate class
    private let logFile: URL = {
        let appSupportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appSupportDir = appSupportPath.appendingPathComponent("Dial8")
        
        // Create the directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        return appSupportDir.appendingPathComponent("sparkle_update.log")
    }()

    // Add managers
    @MainActor private var windowManager: WindowManager!
    
    override init() {
        super.init()
        
        // Initialize managers on the main actor
        Task { @MainActor in
            self.windowManager = WindowManager()
        }
    }

    private func logToFile(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"
        
        do {
            if !FileManager.default.fileExists(atPath: logFile.path) {
                try "=== Sparkle Update Log ===\n".write(to: logFile, atomically: true, encoding: .utf8)
            }
            
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(logMessage.data(using: .utf8)!)
            }
        } catch {
            logger.debug("Failed to write to log file: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.debug("🚀 Starting application initialization...")
        
        // Hide all windows - we only want menu bar functionality
        NSApplication.shared.windows.forEach { window in
            window.orderOut(nil)
        }
        
        // Prevent the app from showing in the dock and hide main window
        NSApp.setActivationPolicy(.accessory)
        
        // Register default values
        UserDefaults.registerDefaults()
        
        // Check if this is the first launch and handle onboarding
        if !UserDefaults.standard.hasCompletedOnboarding {
            // For first-time users, show settings window to complete setup
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                self.showOnboardingSettings()
            }
        }
        
        // Perform content migration if needed
        Task {
            await ContentMigrationService.shared.performMigrationIfNeeded()
        }
        
        // Setup feature flags defaults
        FeatureFlags.setupDefaults()
        
        // Set up window transparency for all windows
        NSApplication.shared.windows.forEach { window in
            configureWindow(window)
        }
        
        // Initialize Sparkle Updater with enhanced logging
        // initializeSparkleUpdater() // Commented out to suppress all update checks
        
        
        // Register for text overlay notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSelectedTextOverlay(_:)),
            name: .showSelectedTextOverlay,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissSelectedTextOverlay(_:)),
            name: .dismissSelectedTextOverlay,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.presentLaunchPathAdviceIfNeeded()
        }
    }

    /// macOS tracks privacy per app path; translocated or folder installs need /Applications for stable TCC.
    private func presentLaunchPathAdviceIfNeeded() {
        guard LaunchEnvironment.shouldShowInstallLocationAdvice() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install Dial8 in Applications"
        alert.informativeText = "Opening Dial8 from a folder or disk image can make microphone and accessibility permissions unreliable. Drag Dial8 into your Applications folder and launch it from there (or from Launchpad) so permissions apply consistently."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Don’t Show Again")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            LaunchEnvironment.markInstallLocationAdviceDismissed()
        }
    }

    // MARK: - Sparkle Initialization
    private func initializeSparkleUpdater() {
        logger.debug("📦 Initializing Sparkle updater...")
        
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        
        let updater = updaterController.updater
        
        // Set user agent string for better tracking
        updater.userAgentString = "Dial8/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown")"
        
        // Configure HTTP headers
        updater.httpHeaders = [
            "Accept": "application/octet-stream"
        ]
        
        // Reset update cycle to ensure clean state
        updater.resetUpdateCycle()
        
        // Existing configuration checks...
        if let feedURL = Bundle.main.infoDictionary?["SUFeedURL"] as? String,
           let url = URL(string: feedURL) {
            logger.debug("📡 Feed URL configured: \(url)")
            // Verify HTTPS
            if url.scheme?.lowercased() != "https" {
                logger.warning("⚠️ Warning: Feed URL should use HTTPS for security")
            }
        }
        
        // Add version checking
        if let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            logger.debug("📱 Current version: \(currentVersion)")
            // Check for updates after a short delay
            // DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            //     self?.updaterController.checkForUpdates(nil)
            // }
        }
        
        // Verify EdDSA key presence
        if let edKey = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String {
            logger.debug("📝 EdDSA Key found: \(String(edKey.prefix(10)))...")
        } else {
            logger.warning("⚠️ Warning: No EdDSA Key found in Info.plist")
        }
        
        // Configure installation path
        let bundleURL = Bundle.main.bundleURL
        let installerURL = bundleURL.appendingPathComponent(
            "Contents/Frameworks/Sparkle.framework/Versions/Current/Resources/Autoupdate.app"
        )
        UserDefaults.standard.set(installerURL.path, forKey: "SUInstallerPath")
        
        // Verify installation directory permissions
        do {
            let resourceValues = try bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            if let isReadOnly = resourceValues.volumeIsReadOnly, isReadOnly {
                logger.warning("⚠️ Warning: Application is installed on a read-only volume")
            }
        } catch {
            logger.error("❌ Error checking installation directory: \(error)")
        }
        
        // Log configuration
        logger.debug("✅ Sparkle updater initialized successfully")
        if let feedURL = updater.feedURL {
            logger.debug("📡 Feed URL: \(feedURL)")
            logger.debug("🔍 Checking appcast content...")
            checkAppcastContent(url: feedURL)
        }
        
        logger.debug("📋 Update configuration:")
        logger.debug("- Automatic checks enabled: \(updater.automaticallyChecksForUpdates)")
        logger.debug("- Check interval: \(updater.updateCheckInterval) seconds")
        
        // Single check for updates
        // DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        //     self.checkForUpdatesIfNeeded()
        // }
        
        // Add verification for required Info.plist keys
        let requiredKeys = [
            "SUEnableInstallerLauncherService",
            "SUPublicEDKey",
            "SUFeedURL"
        ]
        
        for key in requiredKeys {
            if Bundle.main.object(forInfoDictionaryKey: key) == nil {
                logger.warning("⚠️ Warning: Missing required key in Info.plist: \(key)")
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Cleanup if needed
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            switch url.scheme {
            case "com.dial8.oauth":
                // OAuth handling removed
                break
            case "dial8":
                // Deep link handling removed
                break
            default:
                logger.debug("Unhandled URL: \(urls)")
            }
            
            // Activate the existing window instead of creating a new one
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }



    func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: AVMediaType.audio) {
        case .authorized:
            logger.debug("Microphone access previously granted")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: AVMediaType.audio) { [weak self] granted in
                self?.logger.debug("Microphone access granted: \(granted)")
                if !granted {
                    // Notify the user that the app requires microphone access
                }
            }
        default:
            logger.debug("Microphone access denied or restricted")
            // Inform the user that microphone access is required
        }
    }


    func applicationDidBecomeActive(_ notification: Notification) {
        // App became active - no special processing needed currently
    }

    func applicationWillResignActive(_ notification: Notification) {
        // Post notification for other components to respond to
        NotificationCenter.default.post(name: .appWillResignActive, object: nil)
    }

    // Add this new method to handle window configuration
    private func configureWindow(_ window: NSWindow) {
        // Check for Sparkle windows by class name or title
        if window.className.contains("Sparkle") || 
           window.title.contains("Update") ||
           window.title.contains("Software Update") ||
           window.title.contains("Updating Dial8") {
            window.backgroundColor = NSColor.black.withAlphaComponent(0.8)
            window.isOpaque = false
            window.titlebarAppearsTransparent = true
            
            // Add visual effect view for HUD appearance
            if let contentView = window.contentView {
                // Remove any existing visual effect views first
                contentView.subviews.forEach { view in
                    if view is NSVisualEffectView {
                        view.removeFromSuperview()
                    }
                }
                
                let visualEffect = NSVisualEffectView()
                visualEffect.material = .hudWindow
                visualEffect.blendingMode = .behindWindow
                visualEffect.state = .active
                
                contentView.addSubview(visualEffect, positioned: .below, relativeTo: nil)
                visualEffect.frame = contentView.bounds
                visualEffect.autoresizingMask = [.width, .height]
            }
            
            return
        }
        
        // Configure transparent style for our app windows
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.styleMask.insert(.fullSizeContentView)
        
        // Style window buttons
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { buttonType in
            window.standardWindowButton(buttonType)?.wantsLayer = true
        }
    }

    // Add this method to handle new windows
    func applicationDidUpdate(_ notification: Notification) {
        NSApplication.shared.windows.forEach { window in
            // Only configure windows that haven't been configured yet
            if window.backgroundColor != .clear {
                configureWindow(window)
            }
        }
    }

    // MARK: - SPUUpdaterDelegate Methods
    
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        isCheckingForUpdates = false
        logger.debug("✅ Successfully loaded appcast")
        
        // Only proceed with update UI if there's a newer version available
        if let firstItem = appcast.items.first,
           let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            
            // Compare versions to determine if we should show any UI
            if firstItem.versionString != currentVersion {
                logger.debug("📦 Update available: \(firstItem.displayVersionString)")
                // Let the normal update UI flow continue
            } else {
                logger.debug("✅ Already on latest version: \(currentVersion)")
                // Suppress the "up-to-date" UI
                updater.automaticallyDownloadsUpdates = false
                return
            }
        }
        
        if let firstItem = appcast.items.first {
            logger.debug("📦 Latest version: \(firstItem.displayVersionString)")
            let signatureValue = firstItem.propertiesDictionary["sparkle:edSignature"]
            let signatureString: String = signatureValue.map { String(describing: $0) } ?? "NO_SIGNATURE"
            logger.debug("🔐 Signature: \(signatureString)")
            
            // Print more details about the item
            logger.debug("📝 Update details:")
            logger.debug("- Version: \(firstItem.versionString)")
            logger.debug("- Display version: \(firstItem.displayVersionString)")
            logger.debug("- Download URL: \(firstItem.fileURL?.absoluteString ?? "nil", privacy: .public)")
            logger.debug("- File size: \(firstItem.contentLength)")
            
            // Print all available properties for debugging
            logger.debug("🔍 All properties:")
            firstItem.propertiesDictionary.forEach { key, value in
                logger.debug("  \(String(describing: key), privacy: .public): \(String(describing: value), privacy: .public)")
            }
        }
    }
    
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        logger.error("❌ Failed to download update for item version \(item.displayVersionString): \(error.localizedDescription)")

        guard let url = item.fileURL else {
            return
        }

        // Try to fetch the update URL directly to check its contents
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, networkError in
            if let networkError = networkError {
                self?.logger.debug("🌐 Network error: \(networkError.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                self?.logger.debug("🌐 HTTP Status: \(httpResponse.statusCode)")
            }
            
            if let data = data, let content = String(data: data, encoding: .utf8) {
                self?.logger.debug("📄 Response preview (update URL): \(content, privacy: .public)")
            }
        }
        task.resume()
    }

    private func checkAppcastContent(url: URL) {
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, networkError in
            if let networkError = networkError {
                self?.logger.error("❌ Appcast fetch error: \(networkError.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                self?.logger.debug("📡 Appcast HTTP Status: \(httpResponse.statusCode)")
            }
            
            if let data = data, let content = String(data: data, encoding: .utf8) {
                self?.logger.debug("📄 Appcast Content: \(content, privacy: .public)")
            }
        }
        task.resume()
    }

    // Add these methods at the bottom of your AppDelegate class
    
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        logToFile("🔄 Preparing to install update...")
        
        // Ensure all windows are properly saved
        NSApplication.shared.windows.forEach { window in
            window.saveFrame(usingName: window.frameAutosaveName)
        }
        
        // Clean up any temporary states
    }
    
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        return Set(["release"])  // or include "beta" if you want beta updates
    }
    
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem) -> Bool {
        // Allow users to save their work
        return false
    }
    
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem) -> Bool {
        logToFile("📦 Will install update on quit")
        return true
    }
    
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        logToFile("🔄 Application will relaunch for update")
        // Perform any cleanup needed before relaunch
    }
    
    func updater(_ updater: SPUUpdater, failedToInstallUpdate item: SUAppcastItem, error: Error) {
        let errorMessage = """
        ❌ Failed to install update: \(error.localizedDescription)
        Domain: \((error as NSError).domain)
        Code: \((error as NSError).code)
        User Info: \((error as NSError).userInfo)
        """
        logToFile(errorMessage)
    }

    // Add this new delegate method
    func updater(_ updater: SPUUpdater, willShowModalAlert alert: NSAlert) {
        let window = alert.window
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
    }

    // Add this delegate method to handle background check results
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        logToFile("📦 Valid update found: \(item.displayVersionString)")
        
        // Show update UI on the main thread
        // DispatchQueue.main.async { [weak self] in
        //     guard let self = self else { return }
        //     self.updaterController.checkForUpdates(nil)
        // }
    }

    // Fix the validation method to use the correct property names
    func updater(_ updater: SPUUpdater, validateUpdate item: SUAppcastItem) throws {
        logToFile("🔍 Validating update: \(item.displayVersionString)")
        let expectedLength = item.contentLength
        logger.debug("🔍 Validating update size: \(expectedLength) bytes")
        
        // Verify minimum system requirements (Sparkle also enforces this; keep a baseline check)
        if item.minimumSystemVersion != nil {
            let baselineMin = OperatingSystemVersion(majorVersion: 10, minorVersion: 13, patchVersion: 0)
            if !ProcessInfo().isOperatingSystemAtLeast(baselineMin) {
                throw NSError(domain: "org.sparkle-project.Sparkle", code: 2001, userInfo: [
                    NSLocalizedDescriptionKey: "Update requires macOS 10.13 or later"
                ])
            }
        }
        
        // Verify signature presence
        if item.propertiesDictionary["sparkle:edSignature"] == nil {
            throw NSError(domain: "org.sparkle-project.Sparkle", code: 2002, userInfo: [
                NSLocalizedDescriptionKey: "Update package is missing required signature"
            ])
        }
        
        // Get the actual file size from the download URL
        if let downloadURL = item.fileURL {
            logger.debug("📦 Download URL: \(downloadURL)")
            logger.debug("📊 Expected size: \(expectedLength) bytes")
        }
    }

    // Add this new method
    private func checkForUpdatesIfNeeded() {
        guard !isCheckingForUpdates,
              let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return
        }
        
        isCheckingForUpdates = true
        logToFile("🔍 Starting update check for version \(currentVersion)")
        
        // Use the updaterController to check for updates silently
        DispatchQueue.main.async {
            // Use checkForUpdatesInBackground instead of checkForUpdates
            // updaterController.updater.checkForUpdatesInBackground()
        }
    }

    // Add new delegate methods for better error handling
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotes items: [SUAppcastItem]) -> Bool {
        // Allow release notes download
        return true
    }
    
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        isCheckingForUpdates = false
        let errorMessage = """
        ❌ Update aborted with error: \(error.localizedDescription)
        Domain: \((error as NSError).domain)
        Code: \((error as NSError).code)
        User Info: \((error as NSError).userInfo)
        """
        logToFile(errorMessage)
    }
    
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        let message = """
        📥 Preparing to download update: \(item.displayVersionString)
        🔗 Download URL: \(request.url?.absoluteString ?? "unknown")
        📋 Request headers: \(request.allHTTPHeaderFields ?? [:])
        """
        logToFile(message)
    }

    // Add this new method to handle text overlay notifications
    @objc private func handleShowSelectedTextOverlay(_ notification: Notification) {
        logger.debug("📱 AppDelegate: handleShowSelectedTextOverlay called")
        
        guard let userInfo = notification.userInfo,
              let selectedText = userInfo["selectedText"] as? String,
              (userInfo["audioManager"] as? AudioManager) != nil else {
            logger.error("❌ AppDelegate: Missing required userInfo in showSelectedTextOverlay notification")
            logger.debug("   userInfo keys: \(notification.userInfo?.keys.map { $0 as? String } ?? [])")
            return
        }
        
        logger.debug("📱 AppDelegate: Selected text: \(selectedText.prefix(20))...")
    }

    @objc private func handleDismissSelectedTextOverlay(_ notification: Notification) {
        logger.debug("📱 AppDelegate: handleDismissSelectedTextOverlay called")
        
        // First detach the child window relationship
        textOverlayController?.detachFromHUD()
        
        // Then hide the overlay
        textOverlayController?.hideAnimated()
        textOverlayController = nil
    }
    
    @MainActor
    private func showOnboardingSettings() {
        // Check if onboarding window already exists
        if let existingWindow = onboardingWindow {
            // Window exists, bring it to front
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            
            // If window is minimized, deminiaturize it
            if existingWindow.isMiniaturized {
                existingWindow.deminiaturize(nil)
            }
            
            // Ensure window is visible
            if !existingWindow.isVisible {
                existingWindow.orderFront(nil)
            }
            
            return
        }
        
        // Create a temporary audio manager for onboarding
        let audioManager = AudioManager()
        
        let contentView = OnboardingView()
            .environmentObject(WindowManager())
            .environmentObject(audioManager)
        
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Dial8"
        window.setContentSize(NSSize(width: 529, height: 756))
        window.minSize = NSSize(width: 397, height: 504)
        window.center()
        
        // Configure window style
        window.backgroundColor = NSColor.windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        
        // Use normal window level so it behaves like a regular app window
        window.level = .normal
        
        // Set delegate to handle window closing
        window.delegate = self
        
        // Store reference to the window
        onboardingWindow = window
        
        // Create window controller to keep window alive
        let windowController = NSWindowController(window: window)
        onboardingWindowController = windowController
        
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

}

// MARK: - NSWindowDelegate
extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Clear the window reference when it closes
        if notification.object as? NSWindow === onboardingWindow {
            onboardingWindow = nil
            onboardingWindowController = nil
        }
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Allow the window to close
        return true
    }
}
#endif
