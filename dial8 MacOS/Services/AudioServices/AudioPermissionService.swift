import Foundation
import AVFoundation
import Combine
import os

#if os(macOS)
import AppKit
#endif

class AudioPermissionService: ObservableObject {
    private let logger = Logger(subsystem: "com.dial8", category: "AudioPermissionService")
    // Published properties for permission states
    @Published var microphonePermissionGranted: Bool = false
    @Published var accessibilityPermissionGranted: Bool = false

    #if os(macOS)
    private var becomeActiveObserver: NSObjectProtocol?
    #endif
    
    init() {
        checkPermissions()
        #if os(macOS)
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkPermissions()
            // TCC can lag slightly after toggling Accessibility in System Settings.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.checkPermissions()
            }
        }
        #endif
    }

    deinit {
        #if os(macOS)
        if let observer = becomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }
    
    // MARK: - Permission Checking
    
    func checkPermissions() {
        // Use PermissionManager for microphone permission
        self.microphonePermissionGranted = PermissionManager.shared.checkMicrophonePermissionSync()

        // Use PermissionManager for accessibility permission
        self.accessibilityPermissionGranted = PermissionManager.shared.checkAccessibilityPermission()
    }
    
    // MARK: - Permission Requesting
    
    func requestMicrophonePermission(completion: @escaping (Bool) -> Void = { _ in }) {
        PermissionManager.shared.requestMicrophonePermission { [weak self] granted in
            self?.logger.debug("Microphone permission granted: \(granted)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.microphonePermissionGranted = granted
                completion(granted)
            }
        }
    }
} 
