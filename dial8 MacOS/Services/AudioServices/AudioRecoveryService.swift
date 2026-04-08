import Foundation
import AVFoundation
import Combine
import os

class AudioRecoveryService: ObservableObject {
    private let logger = Logger(subsystem: "com.dial8", category: "AudioRecoveryService")
    // Dependencies
    private let audioEngineService: AudioEngineService
    
    // State
    @Published private(set) var isRecoveryInProgress = false
    private let retryDelays = [0.5, 1.0, 2.0] // Delays in seconds between recovery attempts
    
    // Callbacks
    var onRecoveryStarted: (() -> Void)?
    var onRecoverySucceeded: (() -> Void)?
    var onRecoveryFailed: (() -> Void)?
    
    init(audioEngineService: AudioEngineService) {
        self.audioEngineService = audioEngineService
    }
    
    /// Attempts to recover the audio engine with multiple retry attempts
    func attemptRecovery() {
        guard !isRecoveryInProgress else {
            logger.debug("Recovery already in progress, ignoring duplicate request")
            return
        }
        
        logger.info("Starting audio engine recovery process")
        isRecoveryInProgress = true
        onRecoveryStarted?()
        
        attemptRecoveryWithIndex(0)
    }
    
    /// Stops any ongoing recovery attempts
    func cancelRecovery() {
        isRecoveryInProgress = false
        logger.info("Audio engine recovery cancelled")
    }
    
    // MARK: - Private Methods
    
    private func attemptRecoveryWithIndex(_ attemptIndex: Int) {
        guard isRecoveryInProgress else {
            logger.debug("Recovery was cancelled, aborting further attempts")
            return
        }
        
        guard attemptIndex < retryDelays.count else {
            logger.error("Audio engine recovery failed after all attempts")
            isRecoveryInProgress = false
            onRecoveryFailed?()
            return
        }
        
        let delay = retryDelays[attemptIndex]
        logger.debug("Recovery attempt \(attemptIndex + 1) will execute in \(delay) seconds")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.isRecoveryInProgress else { return }
            
            logger.debug("Executing recovery attempt \(attemptIndex + 1)")
            
            // Stop the engine first
            self.audioEngineService.stopEngine()
            
            // Set up a new engine
            self.audioEngineService.setupAudioEngine()
            
            // Try to start the engine
            if self.audioEngineService.startEngine() {
                logger.info("Audio engine recovered successfully on attempt \(attemptIndex + 1)")
                self.isRecoveryInProgress = false
                self.onRecoverySucceeded?()
            } else {
                logger.warning("Recovery attempt \(attemptIndex + 1) failed, trying next attempt")
                self.attemptRecoveryWithIndex(attemptIndex + 1)
            }
        }
    }
} 
