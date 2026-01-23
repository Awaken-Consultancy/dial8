import Foundation
import AVFoundation
import Cocoa
import CoreAudio

class AudioSessionService {
    // Callback closures
    var onSessionInterruption: ((Bool) -> Void)?
    var onRouteChange: (() -> Void)?
    var onDeviceChange: ((String?) -> Void)?  // New callback with device name

    // Track last known device to detect actual changes
    private var lastKnownDeviceUID: String?

    init() {
        // Initialize with current device
        lastKnownDeviceUID = getCurrentInputDeviceUID()
        setupAudioSessionNotifications()
    }
    
    // MARK: - Notification Setup
    
    func setupAudioSessionNotifications() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        #endif

        // Add observer for audio route changes (device changes)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: nil
        )
    }
    
    // MARK: - Notification Handlers
    
    @objc func handleAudioSessionInterruption(notification: Notification) {
        #if os(iOS)
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .began {
            print("Audio session interruption began")
            onSessionInterruption?(true)
        } else if type == .ended {
            print("Audio session interruption ended")
            onSessionInterruption?(false)
        }
        #endif
    }

    @objc func handleAudioRouteChange(_ notification: Notification) {
        // Check if this was a user-initiated device change (from dropdown selection)
        // If so, just update our tracking and skip the notification
        if AudioDeviceEnumerationService.shared.consumeUserInitiatedFlag() {
            lastKnownDeviceUID = getCurrentInputDeviceUID()
            print("🎧 Audio route change detected (user-initiated, suppressing notification)")
            return
        }

        // Check if the device actually changed by comparing UIDs
        let currentDeviceUID = getCurrentInputDeviceUID()
        if currentDeviceUID == lastKnownDeviceUID {
            // Device hasn't actually changed - this is just an engine restart
            print("🎧 Audio config change detected (same device, ignoring)")
            return
        }

        // Device actually changed - update tracking and notify
        lastKnownDeviceUID = currentDeviceUID
        print("🎧 Audio route change detected (system - device changed)")

        // Get the new device name
        let deviceName = getCurrentInputDeviceName()
        print("🎤 New input device: \(deviceName ?? "Unknown")")

        // Call both callbacks
        onDeviceChange?(deviceName)
        onRouteChange?()
    }
    
    // MARK: - Device Detection

    func getCurrentInputDeviceUID() -> String? {
        #if os(macOS)
        // First check if user has selected a specific device
        if let selectedUID = AudioDeviceEnumerationService.shared.selectedDeviceUID {
            return selectedUID
        }

        // Fall back to system default
        var deviceID = AudioDeviceID(0)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else { return nil }

        // Get the device UID
        propertyAddress.mSelector = kAudioDevicePropertyDeviceUID
        var deviceUID: CFString?
        dataSize = UInt32(MemoryLayout<CFString?>.size)

        let uidStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceUID
        )

        guard uidStatus == noErr, let uid = deviceUID as String? else { return nil }
        return uid
        #else
        return AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
        #endif
    }

    func getCurrentInputDeviceName() -> String? {
        #if os(macOS)
        var deviceID = AudioDeviceID(0)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        // Get the default input device ID
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        
        guard status == noErr else {
            print("Failed to get default input device ID: \(status)")
            return nil
        }
        
        // Get the device name
        propertyAddress.mSelector = kAudioDevicePropertyDeviceNameCFString
        propertyAddress.mScope = kAudioObjectPropertyScopeGlobal
        
        var deviceName: CFString?
        dataSize = UInt32(MemoryLayout<CFString?>.size)
        
        let nameStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceName
        )
        
        guard nameStatus == noErr, let name = deviceName as String? else {
            print("Failed to get device name: \(nameStatus)")
            return nil
        }
        
        return name
        #else
        // iOS implementation would use AVAudioSession
        return AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
        #endif
    }
    
    // MARK: - Cleanup
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

class AudioDuckingService {
    // MARK: - Properties
    
    private var originalVolume: Float32?
    private var isDucked = false
    private let duckingFactor: Float32 = 0.1 // Duck to 10% of original volume
    
    // Safety tracking for volume lag
    private var expectedRestoredVolume: Float32?
    private var lastUnduckTime: Date?
    
    // MARK: - Public Methods
    
    func duck() {
        guard !isDucked else { return }
        
        // Get current system volume
        guard var currentVolume = getSystemVolume() else {
            print("⚠️ AudioDuckingService: Failed to get current system volume")
            return
        }
        
        // Check for volume lag (if we unducked recently but system volume hasn't updated yet)
        if let expected = expectedRestoredVolume,
           let lastTime = lastUnduckTime,
           Date().timeIntervalSince(lastTime) < 1.0 {
            
            // If current volume is close to what it would be if ducked (expected * duckingFactor)
            // and significantly different from what we expect (restored volume)
            // then assume the system hasn't updated yet and use the expected volume
            let previousDuckedLevel = expected * duckingFactor
            
            if abs(currentVolume - previousDuckedLevel) < 0.1 && abs(currentVolume - expected) > 0.1 {
                print("⚠️ AudioDuckingService: Detected volume lag. Using expected volume \(expected) instead of current \(currentVolume)")
                currentVolume = expected
            }
        }
        
        // Store original volume
        originalVolume = currentVolume
        
        // Calculate ducked volume
        let duckedVolume = currentVolume * duckingFactor
        
        // Apply ducked volume
        if setSystemVolume(duckedVolume) {
            isDucked = true
            print("🔉 AudioDuckingService: Ducked volume to \(duckedVolume) (Original: \(currentVolume))")
        } else {
            print("⚠️ AudioDuckingService: Failed to set ducked volume")
        }
    }
    
    func unduck() {
        guard isDucked, let originalVol = originalVolume else { return }
        
        // Restore original volume
        if setSystemVolume(originalVol) {
            print("🔊 AudioDuckingService: Restored volume to \(originalVol)")
            isDucked = false
            originalVolume = nil
            
            // Track expectation for safety
            expectedRestoredVolume = originalVol
            lastUnduckTime = Date()
        } else {
            print("⚠️ AudioDuckingService: Failed to restore volume")
        }
    }
    
    // MARK: - Private Methods
    
    private func getSystemVolume() -> Float32? {
        var deviceID = AudioDeviceID(0)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        // Get default output device
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        
        guard status == noErr else { return nil }
        
        // Get volume
        // Try VirtualMainVolume first
        propertyAddress.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        propertyAddress.mScope = kAudioObjectPropertyScopeOutput
        propertyAddress.mElement = kAudioObjectPropertyElementMain
        
        if !hasProperty(deviceID: deviceID, address: propertyAddress) {
            // Fallback to VolumeScalar
            propertyAddress.mSelector = kAudioDevicePropertyVolumeScalar
        }
        
        var volume: Float32 = 0.0
        dataSize = UInt32(MemoryLayout<Float32>.size)
        
        status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &volume
        )
        
        return status == noErr ? volume : nil
    }
    
    private func setSystemVolume(_ volume: Float32) -> Bool {
        var deviceID = AudioDeviceID(0)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        // Get default output device
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        
        guard status == noErr else { return false }
        
        // Set volume
        propertyAddress.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        propertyAddress.mScope = kAudioObjectPropertyScopeOutput
        propertyAddress.mElement = kAudioObjectPropertyElementMain
        
        // Try VirtualMainVolume first
        if hasProperty(deviceID: deviceID, address: propertyAddress) {
            // VirtualMainVolume is settable
        } else {
            // Fallback to VolumeScalar
            propertyAddress.mSelector = kAudioDevicePropertyVolumeScalar
        }
        
        // Check if property is settable
        var isSettable: DarwinBoolean = false
        status = AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isSettable)
        
        guard status == noErr && isSettable.boolValue else {
            print("⚠️ AudioDuckingService: Volume property is not settable")
            return false
        }
        
        var newVolume = volume
        // Clamp volume between 0.0 and 1.0
        newVolume = max(0.0, min(1.0, newVolume))
        
        dataSize = UInt32(MemoryLayout<Float32>.size)
        
        status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            dataSize,
            &newVolume
        )
        
        return status == noErr
    }
    
    private func hasProperty(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) -> Bool {
        var mutableAddress = address
        return AudioObjectHasProperty(deviceID, &mutableAddress)
    }
}

