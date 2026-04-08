import Foundation

// MARK: - UserDefaults Keys

/// Centralized, type-safe access to all UserDefaults keys used throughout the app.
/// Replaces scattered string literals with a single source of truth.
enum AppSettingsKeys: String {
    // Core Settings
    case selectedLanguage
    case useLocalWhisperModel
    case streamingModeEnabled
    case fnKeySetupComplete
    case hasCompletedOnboarding
    
    // Speech & Audio
    case selectedSpeechEngine = "SelectedSpeechEngine"
    case selectedWhisperModel = "SelectedWhisperModel"
    case pauseDetectionThreshold
    case selectedAudioDeviceUID = "audioDeviceSelectedUID"
    
    // Hotkeys
    case triggerMode
    case hotkeyConfigurationsVersion
    case hotkeyConfigurations
    
    // HUD
    case hudWindowFrame = "HUDWindowFrame"
    case hudSoundsEnabled = "HUDSoundsEnabled"
    case hudOpenSound = "HUDOpenSound"
    case hudReadySound = "HUDReadySound"
    case hudCloseSound = "HUDCloseSound"
    case hudProcessingSound = "HUDProcessingSound"
    
    // Transcription
    case selectedTone
    case enableTranscriptionCleaning
    case enableAutoPunctuation
    
    // Text Replacements
    case textReplacements
    case textReplacementsEnabled
    
    // Onboarding & Dev
    case simulateFirstLaunch
    case showOnboardingInDevMode
    case currentOnboardingStep
    case microphonePermissionGranted
    case accessibilityPermissionGranted
    
    // History
    case transcriptionHistory
    
    // Misc
    case sparkleInstallerPath = "SUInstallerPath"
    case dismissedAdviceKey = "dismissedAdvice"
}

// MARK: - AppSettings

/// Type-safe, centralized access to app settings stored in UserDefaults.
/// Use this instead of direct UserDefaults access with string keys.
struct AppSettings {
    static let shared = AppSettings()
    
    private let defaults: UserDefaults
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
    // MARK: - Core Settings
    
    var selectedLanguage: String {
        get { defaults.string(forKey: AppSettingsKeys.selectedLanguage.rawValue) ?? "english" }
        set { defaults.set(newValue, forKey: AppSettingsKeys.selectedLanguage.rawValue) }
    }
    
    var useLocalWhisperModel: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.useLocalWhisperModel.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.useLocalWhisperModel.rawValue) }
    }
    
    var streamingModeEnabled: Bool {
        get { defaults.object(forKey: AppSettingsKeys.streamingModeEnabled.rawValue) as? Bool ?? false }
        set { defaults.set(newValue, forKey: AppSettingsKeys.streamingModeEnabled.rawValue) }
    }
    
    var fnKeySetupComplete: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.fnKeySetupComplete.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.fnKeySetupComplete.rawValue) }
    }
    
    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.hasCompletedOnboarding.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.hasCompletedOnboarding.rawValue) }
    }
    
    // MARK: - Speech & Audio
    
    var selectedSpeechEngine: String? {
        get { defaults.string(forKey: AppSettingsKeys.selectedSpeechEngine.rawValue) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: AppSettingsKeys.selectedSpeechEngine.rawValue)
            } else {
                defaults.removeObject(forKey: AppSettingsKeys.selectedSpeechEngine.rawValue)
            }
        }
    }
    
    var selectedWhisperModel: String? {
        get { defaults.string(forKey: AppSettingsKeys.selectedWhisperModel.rawValue) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: AppSettingsKeys.selectedWhisperModel.rawValue)
            } else {
                defaults.removeObject(forKey: AppSettingsKeys.selectedWhisperModel.rawValue)
            }
        }
    }
    
    var pauseDetectionThreshold: Double {
        get { defaults.double(forKey: AppSettingsKeys.pauseDetectionThreshold.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.pauseDetectionThreshold.rawValue) }
    }
    
    var selectedAudioDeviceUID: String? {
        get { defaults.string(forKey: AppSettingsKeys.selectedAudioDeviceUID.rawValue) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: AppSettingsKeys.selectedAudioDeviceUID.rawValue)
            } else {
                defaults.removeObject(forKey: AppSettingsKeys.selectedAudioDeviceUID.rawValue)
            }
        }
    }
    
    // MARK: - Hotkeys
    
    var triggerMode: String? {
        get { defaults.string(forKey: AppSettingsKeys.triggerMode.rawValue) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: AppSettingsKeys.triggerMode.rawValue)
            } else {
                defaults.removeObject(forKey: AppSettingsKeys.triggerMode.rawValue)
            }
        }
    }
    
    var hotkeyConfigurationsVersion: Int {
        get { defaults.integer(forKey: AppSettingsKeys.hotkeyConfigurationsVersion.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.hotkeyConfigurationsVersion.rawValue) }
    }
    
    var hotkeyConfigurationsData: Data? {
        get { defaults.data(forKey: AppSettingsKeys.hotkeyConfigurations.rawValue) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: AppSettingsKeys.hotkeyConfigurations.rawValue)
            } else {
                defaults.removeObject(forKey: AppSettingsKeys.hotkeyConfigurations.rawValue)
            }
        }
    }
    
    // MARK: - HUD
    
    var hudWindowFrame: [String: Any]? {
        get { defaults.dictionary(forKey: AppSettingsKeys.hudWindowFrame.rawValue) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: AppSettingsKeys.hudWindowFrame.rawValue)
            } else {
                defaults.removeObject(forKey: AppSettingsKeys.hudWindowFrame.rawValue)
            }
        }
    }
    
    var hudSoundsEnabled: Bool {
        get { defaults.object(forKey: AppSettingsKeys.hudSoundsEnabled.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: AppSettingsKeys.hudSoundsEnabled.rawValue) }
    }
    
    var hudOpenSound: String {
        get { defaults.string(forKey: AppSettingsKeys.hudOpenSound.rawValue) ?? "Frog" }
        set { defaults.set(newValue, forKey: AppSettingsKeys.hudOpenSound.rawValue) }
    }
    
    var hudReadySound: String {
        get { defaults.string(forKey: AppSettingsKeys.hudReadySound.rawValue) ?? "Pop" }
        set { defaults.set(newValue, forKey: AppSettingsKeys.hudReadySound.rawValue) }
    }
    
    var hudCloseSound: String {
        get { defaults.string(forKey: AppSettingsKeys.hudCloseSound.rawValue) ?? "Bottle" }
        set { defaults.set(newValue, forKey: AppSettingsKeys.hudCloseSound.rawValue) }
    }
    
    var hudProcessingSound: String {
        get { defaults.string(forKey: AppSettingsKeys.hudProcessingSound.rawValue) ?? "Tink" }
        set { defaults.set(newValue, forKey: AppSettingsKeys.hudProcessingSound.rawValue) }
    }
    
    // MARK: - Transcription
    
    var selectedTone: String {
        get { defaults.string(forKey: AppSettingsKeys.selectedTone.rawValue) ?? "professional" }
        set { defaults.set(newValue, forKey: AppSettingsKeys.selectedTone.rawValue) }
    }
    
    var enableTranscriptionCleaning: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.enableTranscriptionCleaning.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.enableTranscriptionCleaning.rawValue) }
    }
    
    var enableAutoPunctuation: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.enableAutoPunctuation.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.enableAutoPunctuation.rawValue) }
    }
    
    // MARK: - Text Replacements
    
    var textReplacementsData: Data? {
        get { defaults.data(forKey: AppSettingsKeys.textReplacements.rawValue) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: AppSettingsKeys.textReplacements.rawValue)
            } else {
                defaults.removeObject(forKey: AppSettingsKeys.textReplacements.rawValue)
            }
        }
    }
    
    var textReplacementsEnabled: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.textReplacementsEnabled.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.textReplacementsEnabled.rawValue) }
    }
    
    // MARK: - Onboarding & Dev
    
    var simulateFirstLaunch: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.simulateFirstLaunch.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.simulateFirstLaunch.rawValue) }
    }
    
    var showOnboardingInDevMode: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.showOnboardingInDevMode.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.showOnboardingInDevMode.rawValue) }
    }
    
    var currentOnboardingStep: Int {
        get { defaults.integer(forKey: AppSettingsKeys.currentOnboardingStep.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.currentOnboardingStep.rawValue) }
    }
    
    var microphonePermissionGranted: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.microphonePermissionGranted.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.microphonePermissionGranted.rawValue) }
    }
    
    var accessibilityPermissionGranted: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.accessibilityPermissionGranted.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.accessibilityPermissionGranted.rawValue) }
    }
    
    // MARK: - History
    
    var transcriptionHistoryData: Data? {
        get { defaults.data(forKey: AppSettingsKeys.transcriptionHistory.rawValue) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: AppSettingsKeys.transcriptionHistory.rawValue)
            } else {
                defaults.removeObject(forKey: AppSettingsKeys.transcriptionHistory.rawValue)
            }
        }
    }
    
    // MARK: - Misc
    
    var sparkleInstallerPath: String? {
        get { defaults.string(forKey: AppSettingsKeys.sparkleInstallerPath.rawValue) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: AppSettingsKeys.sparkleInstallerPath.rawValue)
            } else {
                defaults.removeObject(forKey: AppSettingsKeys.sparkleInstallerPath.rawValue)
            }
        }
    }
    
    var dismissedAdvice: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.dismissedAdviceKey.rawValue) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.dismissedAdviceKey.rawValue) }
    }
    
    // MARK: - Utility Methods
    
    /// Check if a key exists in UserDefaults
    func contains(_ key: AppSettingsKeys) -> Bool {
        return defaults.object(forKey: key.rawValue) != nil
    }
    
    /// Remove a value for a specific key
    func remove(_ key: AppSettingsKeys) {
        defaults.removeObject(forKey: key.rawValue)
    }
    
    /// Register default values for settings that don't exist yet
    func registerDefaults() {
        let defaults: [String: Any] = [
            AppSettingsKeys.selectedLanguage.rawValue: "english",
            AppSettingsKeys.useLocalWhisperModel.rawValue: true,
            AppSettingsKeys.streamingModeEnabled.rawValue: false,
            AppSettingsKeys.hasCompletedOnboarding.rawValue: false,
            AppSettingsKeys.fnKeySetupComplete.rawValue: false,
            AppSettingsKeys.hudSoundsEnabled.rawValue: true,
            AppSettingsKeys.hudOpenSound.rawValue: "Frog",
            AppSettingsKeys.hudReadySound.rawValue: "Pop",
            AppSettingsKeys.hudCloseSound.rawValue: "Bottle",
            AppSettingsKeys.hudProcessingSound.rawValue: "Tink",
            AppSettingsKeys.selectedTone.rawValue: "professional",
            AppSettingsKeys.enableTranscriptionCleaning.rawValue: false,
            AppSettingsKeys.enableAutoPunctuation.rawValue: false,
            AppSettingsKeys.textReplacementsEnabled.rawValue: true,
            AppSettingsKeys.simulateFirstLaunch.rawValue: false,
            AppSettingsKeys.showOnboardingInDevMode.rawValue: false,
            AppSettingsKeys.currentOnboardingStep.rawValue: 0,
            AppSettingsKeys.microphonePermissionGranted.rawValue: false,
            AppSettingsKeys.accessibilityPermissionGranted.rawValue: false,
            AppSettingsKeys.dismissedAdviceKey.rawValue: false
        ]
        self.defaults.register(defaults: defaults)
    }
}
