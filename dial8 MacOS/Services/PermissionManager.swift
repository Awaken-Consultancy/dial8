/// PermissionManager is a singleton service that handles all system-level permission requests and checks.
/// It provides a centralized way to manage:
/// - Microphone permissions for audio capture
/// - Accessibility permissions for system-wide features
/// - System preferences navigation for permission settings
///
/// Usage:
/// ```swift
/// // Check microphone permission
/// PermissionManager.shared.checkMicrophonePermission { granted in
///     if granted {
///         // Handle granted permission
///     }
/// }
///
/// // Check accessibility permission
/// if PermissionManager.shared.checkAccessibilityPermission() {
///     // Handle granted permission
/// }
/// ```

import AVFoundation
import ApplicationServices
import Speech
import os

#if os(macOS)
import AppKit
import Darwin
#endif

class PermissionManager {
    private let logger = Logger(subsystem: "com.dial8", category: "PermissionManager")
    static let shared = PermissionManager()
    
    private init() {}
    
    // MARK: - Microphone Permission
    
    /// Uses `AVAudioApplication` on macOS 14+ so permission matches `AVAudioEngine` capture.
    /// Falls back to `AVCaptureDevice` on older macOS (and non-macOS targets if compiled).
    func checkMicrophonePermission(completion: @escaping (Bool) -> Void) {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            let granted = AVAudioApplication.shared.recordPermission == .granted
            DispatchQueue.main.async {
                completion(granted)
            }
        } else {
            let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let granted = permissionStatus == .authorized
            DispatchQueue.main.async {
                completion(granted)
            }
        }
        #else
        let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted = permissionStatus == .authorized
        DispatchQueue.main.async {
            completion(granted)
        }
        #endif
    }
    
    func checkMicrophonePermissionSync() -> Bool {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        #else
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        #endif
    }
    
    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        logger.debug("🎤 Requesting microphone permission...")
        #if os(macOS)
        if #available(macOS 14.0, *) {
            let status = AVAudioApplication.shared.recordPermission
            logger.debug("🎤 Current microphone status (AVAudioApplication): \(String(describing: status))")
            
            switch status {
            case .undetermined:
                logger.debug("🎤 Showing system microphone permission prompt...")
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    self?.logger.debug("🎤 User responded to microphone prompt: \(granted)")
                    DispatchQueue.main.async {
                        completion(granted)
                    }
                }
            case .denied:
                logger.debug("🎤 Microphone permission previously denied, opening System Settings...")
                DispatchQueue.main.async {
                    self.openSystemPreferencesPrivacyMicrophone()
                    completion(false)
                }
            case .granted:
                logger.debug("🎤 Microphone already authorized")
                DispatchQueue.main.async {
                    completion(true)
                }
            @unknown default:
                logger.debug("🎤 Unknown microphone permission status")
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        } else {
            requestMicrophonePermissionLegacyAVCapture(completion: completion)
        }
        #else
        requestMicrophonePermissionLegacyAVCapture(completion: completion)
        #endif
    }
    
    private func requestMicrophonePermissionLegacyAVCapture(completion: @escaping (Bool) -> Void) {
        let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.debug("🎤 Current microphone status (AVCaptureDevice): \(permissionStatus.rawValue)")
        
        switch permissionStatus {
        case .notDetermined:
            logger.debug("🎤 Showing system microphone permission prompt...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.logger.debug("🎤 User responded to microphone prompt: \(granted)")
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            logger.debug("🎤 Microphone permission previously denied, opening System Settings...")
            DispatchQueue.main.async {
                self.openSystemPreferencesPrivacyMicrophone()
                completion(false)
            }
        case .authorized:
            logger.debug("🎤 Microphone already authorized")
            DispatchQueue.main.async {
                completion(true)
            }
        @unknown default:
            logger.debug("🎤 Unknown microphone permission status")
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }
    
    // MARK: - Speech Recognition Permission
    
    func checkSpeechRecognitionPermission(completion: @escaping (Bool) -> Void) {
        let status = SFSpeechRecognizer.authorizationStatus()
        DispatchQueue.main.async {
            completion(status == .authorized)
        }
    }
    
    func checkSpeechRecognitionPermissionSync() -> Bool {
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }
    
    func requestSpeechRecognitionPermission(completion: @escaping (Bool) -> Void) {
        logger.debug("🗣️ Requesting speech recognition permission...")
        let status = SFSpeechRecognizer.authorizationStatus()
        logger.debug("🗣️ Current speech recognition status: \(status.rawValue)")
        
        switch status {
        case .notDetermined:
            logger.debug("🗣️ Showing system speech recognition prompt...")
            SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
                self?.logger.debug("🗣️ User responded to speech recognition prompt: \(authStatus.rawValue)")
                DispatchQueue.main.async { [weak self] in
                    let granted = authStatus == .authorized
                    if !granted {
                        self?.logger.debug("🗣️ Speech recognition not granted, opening System Settings...")
                        self?.openSystemPreferencesPrivacySpeech()
                    }
                    completion(granted)
                }
            }
        case .denied, .restricted:
            logger.debug("🗣️ Speech recognition previously denied, opening System Settings...")
            DispatchQueue.main.async {
                self.openSystemPreferencesPrivacySpeech()
                completion(false)
            }
        case .authorized:
            logger.debug("🗣️ Speech recognition already authorized")
            DispatchQueue.main.async {
                completion(true)
            }
        @unknown default:
            logger.debug("🗣️ Unknown speech recognition status")
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }
    
    // MARK: - Accessibility Permission
    
    func checkAccessibilityPermission() -> Bool {
        logger.debug("🔑 PERMISSION: Checking accessibility permission")
        #if os(macOS)
        let result = AXIsProcessTrusted()
        logger.debug("🔑 PERMISSION: Accessibility permission status: \(result)")
        #if DEBUG
        if !result {
            logAccessibilityDeniedDeveloperHint()
        }
        #endif
        return result
        #else
        return true
        #endif
    }

    #if os(macOS)
    /// macOS stores Accessibility per *signed binary path*. A build run from Xcode (under DerivedData)
    /// is a different client than an app in `/Applications`, even with the same bundle ID — so enabling
    /// one does not grant the other. This is expected OS behavior, not an app bug.
    ///
    /// Additionally, **lldb** (Run with debugger) can leave `AXIsProcessTrusted()` false even after the
    /// app is enabled in System Settings, until you run without the debugger or launch from Finder.
    #if DEBUG
    private func logAccessibilityDeniedDeveloperHint() {
        let path = Bundle.main.bundlePath
        logger.debug("🔑 PERMISSION: Accessibility is not granted for this running process.")
        logger.debug("🔑 PERMISSION: Bundle path: \(path)")
        if isProcessBeingTracedByDebugger() {
            logger.debug("🔑 PERMISSION: A debugger appears to be attached (e.g. Xcode Run). Accessibility trust often fails in this mode. Quit, then Scheme → Run → uncheck “Debug executable”, or open the built app from Finder. Some setups also require enabling “Xcode” in the same Accessibility list.")
        } else if path.contains("DerivedData") {
            logger.debug("🔑 PERMISSION: You are running from Xcode’s build output. Ensure Dial8 is enabled for this path in System Settings → Privacy & Security → Accessibility.")
        }
        if let bid = Bundle.main.bundleIdentifier {
            logger.debug("🔑 PERMISSION: To reset TCC for this app: `tccutil reset Accessibility \(bid)` then relaunch and enable Dial8 again.")
        }
    }
    #endif

    /// `true` when a debugger is attached (e.g. Xcode). Accessibility APIs often report untrusted in this state.
    private func isProcessBeingTracedByDebugger() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let err = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard err == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Short hint for Settings UI when access is still denied (does not log; uses AX API only).
    func accessibilityDeniedUserHint() -> String? {
        guard !AXIsProcessTrusted() else { return nil }
        #if DEBUG
        if isProcessBeingTracedByDebugger() {
            return "Accessibility may not apply while the Xcode debugger is attached. In Scheme → Run, turn off “Debug executable”, or open Dial8 from Finder (not via Run)."
        }
        #endif
        let path = Bundle.main.bundlePath
        let isTypicalXcodeOutput = path.contains("DerivedData") || path.contains("/Build/Products/")
        if !LaunchEnvironment.isInstalledUnderApplications && !isTypicalXcodeOutput {
            return "For reliable permissions, put Dial8 in your Applications folder and open it from there. Then enable Dial8 in System Settings → Privacy & Security → Accessibility."
        }
        return "Enable Dial8 in System Settings → Privacy & Security → Accessibility. If it’s already on, quit Dial8 completely and reopen."
    }
    #endif
    
    func requestAccessibilityPermissionWithPrompt(completion: @escaping (Bool) -> Void) {
        logger.debug("🔑 Requesting accessibility permission...")
        
        #if os(macOS)
        let currentStatus = AXIsProcessTrusted()
        logger.debug("🔑 Current accessibility status: \(currentStatus)")
        
        // Must use takeUnretainedValue — the key is a global CFString (same as AccessibilityTextInsertion).
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let promptShown = AXIsProcessTrustedWithOptions(options)
        logger.debug("🔑 Accessibility prompt shown: \(promptShown)")
        
        // Give the user a moment to respond to the prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let newStatus = AXIsProcessTrusted()
            self?.logger.debug("🔑 New accessibility status: \(newStatus)")
            
            if !newStatus {
                self?.logger.debug("🔑 Permission not granted, opening System Settings...")
                self?.openAccessibilitySettings()
            }
            
            completion(newStatus)
        }
        #else
        DispatchQueue.main.async {
            completion(true)
        }
        #endif
    }
    
    // MARK: - System Settings (privacy panes)

    /// Opens the Accessibility pane (macOS 13+ System Settings URL, with fallback).
    func openAccessibilitySettings() {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?privacy_Accessibility") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
    
    func openSystemPreferencesPrivacyMicrophone() {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?privacy_Microphone") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
    
    func openSystemPreferencesPrivacySpeech() {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?privacy_SpeechRecognition") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
