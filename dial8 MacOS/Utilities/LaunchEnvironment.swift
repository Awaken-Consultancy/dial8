import Foundation

/// Detects launch contexts where macOS privacy (TCC) is unreliable unless the app lives in `/Applications`.
enum LaunchEnvironment {
    private static let dismissedAdviceKey = "dismissedLaunchPathAdvice"

    /// True when Gatekeeper runs the app from a randomized path (common for DMG / not moved to Applications).
    static var isAppTranslocated: Bool {
        Bundle.main.bundlePath.contains("AppTranslocation")
    }

    static var isInstalledUnderApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// Offer one-time guidance when the app is not in a stable install location (excludes typical Xcode output paths).
    static func shouldShowInstallLocationAdvice() -> Bool {
        if UserDefaults.standard.bool(forKey: dismissedAdviceKey) { return false }
        let path = Bundle.main.bundlePath
        if isInstalledUnderApplications { return false }
        if path.contains("DerivedData") { return false }
        if path.contains("/Build/Products/") { return false }
        if isAppTranslocated { return true }
        return true
    }

    static func markInstallLocationAdviceDismissed() {
        UserDefaults.standard.set(true, forKey: dismissedAdviceKey)
    }
}
