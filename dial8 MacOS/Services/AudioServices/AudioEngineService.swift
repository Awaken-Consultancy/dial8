import AVFoundation
import Foundation
import Combine
import CoreAudio
import AudioToolbox
import os

enum AudioEngineState {
    case inactive      // Fully stopped
    case warmStandby   // Engine running but not recording
    case streaming     // Active recording with streaming functionality
}

class AudioEngineService: ObservableObject {
    private let logger = Logger(subsystem: "com.dial8", category: "AudioEngineService")

    private(set) var audioEngine: AVAudioEngine?
    @Published private(set) var engineState: AudioEngineState = .inactive

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var isConfigurationPending = false

    // Added converterNode for sample rate conversion
    private var converterNode: AVAudioMixerNode?

    private var isRecoveryInProgress = false
    private var currentFormat: AVAudioFormat?
    private var deviceChangeObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?
    private var inputDeviceChangeObserver: NSObjectProtocol?

    private var audioConverter: AVAudioConverter?

    init() {
        setupNotifications()
        setupInputDeviceChangeObserver()
        // Don't automatically setup the audio engine
        // It will be setup when needed
    }
    
    private func setupNotifications() {
        // Remove any existing observers
        if let observer = deviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // Observe system device changes
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.logger.debug("AudioEngineService: Device configuration change detected")
                self?.handleDeviceChange()
        }
        
        // Observe audio engine configuration changes
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main) { [weak self] _ in
                self?.logger.debug("AudioEngineService: Engine configuration change detected")
                self?.handleConfigurationChange()
        }
    }
    
    private func setupInputDeviceChangeObserver() {
        inputDeviceChangeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SelectedInputDeviceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.debug("AudioEngineService: Selected input device changed, reconfiguring...")
            self?.reconfigureEngine()
        }
    }

    private func configureInputDevice() {
        guard let audioEngine = audioEngine else { return }

        // Get the selected device from AudioDeviceEnumerationService
        let deviceService = AudioDeviceEnumerationService.shared

        guard let _ = deviceService.selectedDeviceUID,
              let deviceID = deviceService.getDeviceIDForSelectedDevice() else {
            // Use system default - no configuration needed
            logger.debug("AudioEngineService: Using system default input device")
            return
        }

        // Set the input device for AVAudioEngine using AudioUnit
        let inputNode = audioEngine.inputNode

        guard let audioUnit = inputNode.audioUnit else {
            logger.debug("AudioEngineService: Failed to get audio unit from input node")
            return
        }

        var deviceIDValue = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDValue,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status == noErr {
            logger.debug("AudioEngineService: Set input device to ID \(deviceID) (\(deviceService.getCurrentDeviceName()))")
        } else {
            logger.debug("AudioEngineService: Failed to set input device: \(status)")
        }
    }

    private func handleDeviceChange() {
        // Skip if this is a user-initiated device change (handled by reconfigureEngine)
        if AudioDeviceEnumerationService.shared.isUserInitiatedDeviceChange {
            logger.debug("AudioEngineService: Device change detected (user-initiated, skipping)")
            return
        }
        logger.debug("AudioEngineService: Device change detected (system)")
        gracefulReconfiguration(delay: 0.3)
    }

    private func handleConfigurationChange() {
        // Skip if this is a user-initiated device change (handled by reconfigureEngine)
        if AudioDeviceEnumerationService.shared.isUserInitiatedDeviceChange {
            logger.debug("AudioEngineService: Config change detected (user-initiated, skipping)")
            return
        }
        logger.debug("AudioEngineService: Configuration change detected (system)")
        gracefulReconfiguration(delay: 0.1)
    }
    
    private func gracefulReconfiguration(delay: TimeInterval) {
        // Only reconfigure if not already in progress
        guard !isConfigurationPending && !isRecoveryInProgress else {
            logger.debug("AudioEngineService: Reconfiguration already in progress")
            return
        }
        
        isConfigurationPending = true
        engineState = .inactive
        
        // Stop engine gracefully
        if let converter = converterNode {
            converter.removeTap(onBus: 0)
            converterNode = nil
        }
        
        audioEngine?.stop()
        audioEngine = nil
        currentFormat = nil
        audioConverter = nil
        
        // Wait before reconfiguring
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            
            // Setup new engine
            self.setupAudioEngine()
            
            // Wait for engine to be ready before restoring state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                // Always reset the pending flag regardless of engine state
                // Previously this only reset on warmStandby, leaving it stuck
                // if the engine failed to start or entered recovery
                self.isConfigurationPending = false
                
                if self.engineState == .warmStandby {
                    self.logger.debug("AudioEngineService: Graceful reconfiguration completed successfully")
                } else {
                    self.logger.debug("AudioEngineService: Graceful reconfiguration completed, engine state: \(String(describing: self.engineState))")
                }
            }
        }
    }
    
    func setupAudioEngine() {
        logger.debug("AudioEngineService: Setting up audio engine - START")

        // Clean up existing engine if any
        stopEngine()

        // Create new engine
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            logger.debug("AudioEngineService: Failed to create audio engine")
            return
        }

        // Configure selected input device before accessing input node
        configureInputDevice()

        // Get the native input format
        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.inputFormat(forBus: 0)
        logger.debug("AudioEngineService: Native input format: \(nativeFormat)")
        
        // Create and configure converter node
        converterNode = AVAudioMixerNode()
        guard let converterNode = converterNode else {
            logger.debug("AudioEngineService: Failed to create converter node")
            return
        }
        
        // Set converter node volume to 0 to prevent monitoring
        converterNode.volume = 0
        
        // Add converter node to engine
        audioEngine.attach(converterNode)
        
        // Connect input to converter using native format
        audioEngine.connect(inputNode, to: converterNode, format: nativeFormat)
        
        // Create a fixed format for speech recognition (16kHz, mono, float32)
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000,
                                         channels: 1,
                                         interleaved: false)
        
        guard let format = desiredFormat else {
            logger.debug("AudioEngineService: Failed to create audio format")
            return
        }
        
        // Store format for future reference
        currentFormat = format
        
        // Create audio converter once
        audioConverter = AVAudioConverter(from: nativeFormat, to: format)
        
        guard let audioConverter = audioConverter else {
            logger.debug("AudioEngineService: Failed to create audio converter")
            return
        }
        
        // Install tap on converter node with native format
        let bufferSize: AVAudioFrameCount = 1024
        converterNode.installTap(onBus: 0, bufferSize: bufferSize, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self, !self.isConfigurationPending else { return }
            
            let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                  frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate))!
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            audioConverter.convert(to: convertedBuffer,
                                 error: &error,
                                 withInputFrom: inputBlock)
            
            if error == nil {
                self.onAudioBuffer?(convertedBuffer)
            } else {
                logger.debug("AudioEngineService: Buffer conversion error: \(error?.localizedDescription ?? "unknown")")
            }
        }
        
        // Prepare engine
        audioEngine.prepare()
        
        // Try to start the engine immediately
        do {
            try audioEngine.start()
            engineState = .warmStandby
            logger.debug("AudioEngineService: Engine initialized and started successfully")
        } catch {
            logger.debug("AudioEngineService: Failed to start engine during setup: \(error)")
            engineState = .inactive
            if !isRecoveryInProgress {
                attemptRecovery()
            }
        }
    }
    
    func startEngine() -> Bool {
        guard let audioEngine = audioEngine else {
            logger.debug("AudioEngineService: No audio engine available")
            return false
        }
        
        do {
            try audioEngine.start()
            engineState = .warmStandby
            logger.debug("AudioEngineService: Engine started successfully")
            return true
        } catch {
            logger.debug("AudioEngineService: Failed to start engine: \(error)")
            engineState = .inactive
            if !isRecoveryInProgress {
                attemptRecovery()
            }
            return false
        }
    }
    
    func stopEngine() {
        logger.debug("AudioEngineService: Stopping engine...")

        engineState = .inactive

        // Remove tap from converter node if available
        if let converter = converterNode {
            converter.removeTap(onBus: 0)
            converterNode = nil
            logger.debug("AudioEngineService: Removed converter tap")
        }

        // Stop engine if running
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            logger.debug("AudioEngineService: Engine stopped")
        }

        // Clear all references
        audioEngine = nil
        currentFormat = nil
        audioConverter = nil

        logger.debug("AudioEngineService: Engine cleanup complete")
    }
    
    func setStreamingState() {
        // Prevent setting streaming state if configuration is pending
        guard !isConfigurationPending else {
            logger.debug("AudioEngineService: Cannot set streaming state while configuration is pending")
            return
        }
        
        // If already in streaming state, just return
        if engineState == .streaming {
            logger.debug("AudioEngineService: Already in streaming state")
            return
        }
        
        // If engine is not available or not running, set it up
        if audioEngine == nil || !(audioEngine?.isRunning ?? false) {
            logger.debug("AudioEngineService: Setting up new engine for streaming")
            setupAudioEngine()
            
            // Wait for engine to be ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                
                if let engine = self.audioEngine, engine.isRunning {
                    self.engineState = .streaming
                    self.logger.debug("AudioEngineService: Engine ready and set to streaming state")
                } else {
                    self.logger.debug("AudioEngineService: Failed to prepare engine for streaming")
                }
            }
            return
        }
        
        // If we have a running engine, just update the state
        engineState = .streaming
        logger.debug("AudioEngineService: Updated to streaming state")
    }
    
    func reconfigureEngine() {
        logger.debug("AudioEngineService: Reconfiguring engine")

        // Consume the user-initiated flag immediately to prevent spurious system
        // notifications from triggering additional reconfigurations during this process.
        // The isConfigurationPending flag then acts as the guard against duplicates.
        _ = AudioDeviceEnumerationService.shared.consumeUserInitiatedFlag()

        isConfigurationPending = true

        // Stop current engine
        stopEngine()

        // Wait before setting up new engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            self.setupAudioEngine()
            _ = self.startEngine()
            self.isConfigurationPending = false
        }
    }
    
    private func attemptRecovery() {
        isRecoveryInProgress = true
        
        // Try to recover up to 3 times with increasing delays
        let delays = [0.5, 1.0, 2.0]
        
        func attempt(index: Int) {
            guard index < delays.count else {
                self.logger.debug("AudioEngineService: Recovery failed after all attempts")
                self.isRecoveryInProgress = false
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delays[index]) { [weak self] in
                guard let self = self else { return }
                
                self.logger.debug("AudioEngineService: Recovery attempt \(index + 1)")
                self.setupAudioEngine()
                
                if self.startEngine() {
                    self.logger.debug("AudioEngineService: Recovery successful")
                    self.isRecoveryInProgress = false
                } else {
                    attempt(index: index + 1)
                }
            }
        }
        
        attempt(index: 0)
    }
    
    deinit {
        // Remove observers
        if let observer = deviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = inputDeviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopEngine()
    }
} 
