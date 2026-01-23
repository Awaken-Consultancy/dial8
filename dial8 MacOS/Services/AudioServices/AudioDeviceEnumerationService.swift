import Foundation
import CoreAudio
import os

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    static func == (lhs: AudioInputDevice, rhs: AudioInputDevice) -> Bool {
        return lhs.id == rhs.id
    }
}

class AudioDeviceEnumerationService: ObservableObject {
    static let shared = AudioDeviceEnumerationService()
    private let logger = Logger(subsystem: "com.dial8", category: "AudioDeviceEnumeration")

    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedDeviceUID: String?

    /// Flag to track user-initiated device changes (dropdown selection)
    /// This helps distinguish from system device changes (plug/unplug)
    var isUserInitiatedDeviceChange = false

    private let selectedDeviceKey = "selectedInputDeviceUID"

    private init() {
        loadSelectedDevice()
        enumerateInputDevices()
        setupDeviceChangeListener()
    }

    // MARK: - Device Enumeration

    func enumerateInputDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            logger.error("Failed to get audio devices data size: \(status)")
            return
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            logger.error("Failed to get audio devices: \(status)")
            return
        }

        // Filter for input devices only
        var devices: [AudioInputDevice] = []

        for deviceID in deviceIDs {
            if hasInputStreams(deviceID: deviceID) {
                if let name = getDeviceName(deviceID: deviceID),
                   let uid = getDeviceUID(deviceID: deviceID) {
                    devices.append(AudioInputDevice(id: deviceID, name: name, uid: uid))
                }
            }
        }

        DispatchQueue.main.async {
            self.inputDevices = devices
            self.logger.info("Found \(devices.count) input devices")
        }
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)

        return status == noErr && dataSize > 0
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceName: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceName
        )

        guard status == noErr, let name = deviceName as String? else {
            return nil
        }

        return name
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceUID: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceUID
        )

        guard status == noErr, let uid = deviceUID as String? else {
            return nil
        }

        return uid
    }

    // MARK: - Device Change Listener

    private func setupDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.enumerateInputDevices()
        }
    }

    // MARK: - Device Selection

    func selectDevice(uid: String?) {
        // Mark this as a user-initiated change to suppress spurious notifications
        isUserInitiatedDeviceChange = true

        selectedDeviceUID = uid
        saveSelectedDevice()

        logger.info("Selected input device: \(uid ?? "System Default")")

        // Notify AudioEngineService to reconfigure
        NotificationCenter.default.post(
            name: NSNotification.Name("SelectedInputDeviceChanged"),
            object: nil,
            userInfo: ["deviceUID": uid as Any]
        )
    }

    /// Check and consume the user-initiated flag (returns true and resets if it was set)
    func consumeUserInitiatedFlag() -> Bool {
        let wasUserInitiated = isUserInitiatedDeviceChange
        isUserInitiatedDeviceChange = false
        return wasUserInitiated
    }

    private func loadSelectedDevice() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: selectedDeviceKey)
    }

    private func saveSelectedDevice() {
        if let uid = selectedDeviceUID {
            UserDefaults.standard.set(uid, forKey: selectedDeviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedDeviceKey)
        }
    }

    func getDeviceIDForSelectedDevice() -> AudioDeviceID? {
        guard let uid = selectedDeviceUID else { return nil }
        return inputDevices.first { $0.uid == uid }?.id
    }

    func getCurrentDeviceName() -> String {
        if let uid = selectedDeviceUID,
           let device = inputDevices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return "System Default"
    }
}
