import Foundation
import Speech
import AVFoundation
import os

class AppleSpeechRecognizer: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.dial8", category: "AppleSpeechRecognizer")
    static let shared = AppleSpeechRecognizer()
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    
    @Published var isListening = false
    @Published var isSpeechDetected = false
    
    // Callback for when speech is detected
    var onSpeechDetected: (() -> Void)?
    // Callback for when silence is detected
    var onSilenceDetected: (() -> Void)?
    
    private var silenceTimer: Timer?
    private var defaultSilenceThreshold: TimeInterval = 0.8
    private var meetingSilenceThreshold: TimeInterval = 1.5
    private var silenceThreshold: TimeInterval = 0.8
    private var currentRecordingMode: RecordingMode?
    
    override private init() {
        super.init()
        requestAuthorization()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pauseDetectionThresholdChanged(_:)),
            name: NSNotification.Name("PauseDetectionThresholdChanged"),
            object: nil
        )
        
        let storedThreshold = UserDefaults.standard.double(forKey: "pauseDetectionThreshold")
        if storedThreshold > 0 {
            silenceThreshold = storedThreshold
            meetingSilenceThreshold = storedThreshold
        }
    }
    
    private func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch status {
                case .authorized:
                    self.logger.debug("Speech recognition authorized")
                case .denied:
                    self.logger.debug("Speech recognition authorization denied")
                case .restricted:
                    self.logger.debug("Speech recognition restricted on this device")
                case .notDetermined:
                    self.logger.debug("Speech recognition not yet authorized")
                @unknown default:
                    self.logger.debug("Unknown authorization status")
                }
            }
        }
    }
    
    func setRecordingMode(_ mode: RecordingMode?) {
        currentRecordingMode = mode
        
        let storedThreshold = UserDefaults.standard.double(forKey: "pauseDetectionThreshold")
        if storedThreshold > 0 {
            silenceThreshold = storedThreshold
        } else {
            silenceThreshold = meetingSilenceThreshold
        }
        
        logger.debug("🎙️ Set transcription silence threshold: \(self.silenceThreshold) seconds")
        
        if silenceTimer != nil {
            resetSilenceTimer()
        }
    }
    
    func startListening(with engine: AVAudioEngine) {
        guard engine.isRunning else {
            logger.debug("Cannot start listening - engine is not running")
            return
        }
        
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            logger.debug("Speech recognition not authorized")
            requestAuthorization()
            return
        }
        
        if isListening && self.audioEngine === engine && recognitionTask != nil {
            logger.debug("Already listening with valid task")
            return
        }
        
        stopListening()
        
        DispatchQueue.main.async {
            self.isSpeechDetected = false
        }
        
        self.audioEngine = engine
        
        guard let speechRecognizer = self.speechRecognizer, speechRecognizer.isAvailable else {
            logger.debug("Speech recognizer not available")
            return
        }
        
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = self.recognitionRequest else {
            logger.debug("Failed to create recognition request")
            return
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        
        logger.debug("Setting up speech recognition using shared audio buffers")
        
        self.recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result, !result.bestTranscription.segments.isEmpty {
                self.resetSilenceTimer()
                if !self.isSpeechDetected {
                    self.isSpeechDetected = true
                    DispatchQueue.main.async {
                        self.onSpeechDetected?()
                    }
                }
            }
            
            if let error = error {
                self.logger.debug("Speech recognition error: \(error)")
                if (error as NSError).domain != "kAFAssistantErrorDomain" {
                    self.stopListening()
                }
            }
        }
        
        self.isListening = true
        logger.debug("Speech recognition started successfully")
    }
    
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isListening else { return }
        recognitionRequest?.append(buffer)
    }
    
    func stopListening() {
        logger.debug("Speech recognition stopping - cleaning up resources")
        
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        if let request = recognitionRequest {
            request.endAudio()
            recognitionRequest = nil
            logger.debug("Ended recognition request")
        }
        
        if let task = recognitionTask {
            task.finish()
            task.cancel()
            recognitionTask = nil
            logger.debug("Cancelled recognition task")
        }
        
        audioEngine = nil
        isListening = false
        isSpeechDetected = false
        
        logger.debug("Speech recognition stopped and all resources cleaned up")
    }
    
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceThreshold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.isSpeechDetected {
                self.isSpeechDetected = false
                DispatchQueue.main.async {
                    self.onSilenceDetected?()
                }
            }
        }
    }
    
    @objc private func pauseDetectionThresholdChanged(_ notification: Notification) {
        if let threshold = notification.userInfo?["threshold"] as? Double {
            silenceThreshold = threshold
            defaultSilenceThreshold = threshold
            meetingSilenceThreshold = threshold
            logger.debug("🎙️ Updated pause detection threshold to: \(threshold) seconds")
            
            if isListening && silenceTimer != nil {
                resetSilenceTimer()
            }
        }
    }
}
