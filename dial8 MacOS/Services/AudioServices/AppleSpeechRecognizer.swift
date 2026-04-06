import Foundation
import Speech
import AVFoundation

class AppleSpeechRecognizer: NSObject, ObservableObject {
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
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    print("Speech recognition authorized")
                case .denied:
                    print("Speech recognition authorization denied")
                case .restricted:
                    print("Speech recognition restricted on this device")
                case .notDetermined:
                    print("Speech recognition not yet authorized")
                @unknown default:
                    print("Unknown authorization status")
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
        
        print("🎙️ Set transcription silence threshold: \(silenceThreshold) seconds")
        
        if silenceTimer != nil {
            resetSilenceTimer()
        }
    }
    
    func startListening(with engine: AVAudioEngine) {
        guard engine.isRunning else {
            print("Cannot start listening - engine is not running")
            return
        }
        
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            print("Speech recognition not authorized")
            requestAuthorization()
            return
        }
        
        if isListening && self.audioEngine === engine && recognitionTask != nil {
            print("Already listening with valid task")
            return
        }
        
        stopListening()
        
        DispatchQueue.main.async {
            self.isSpeechDetected = false
        }
        
        self.audioEngine = engine
        
        guard let speechRecognizer = self.speechRecognizer, speechRecognizer.isAvailable else {
            print("Speech recognizer not available")
            return
        }
        
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = self.recognitionRequest else {
            print("Failed to create recognition request")
            return
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        
        print("Setting up speech recognition using shared audio buffers")
        
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
                print("Speech recognition error: \(error)")
                if (error as NSError).domain != "kAFAssistantErrorDomain" {
                    self.stopListening()
                }
            }
        }
        
        self.isListening = true
        print("Speech recognition started successfully")
    }
    
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isListening else { return }
        recognitionRequest?.append(buffer)
    }
    
    func stopListening() {
        print("Speech recognition stopping - cleaning up resources")
        
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        if let request = recognitionRequest {
            request.endAudio()
            recognitionRequest = nil
            print("Ended recognition request")
        }
        
        if let task = recognitionTask {
            task.finish()
            task.cancel()
            recognitionTask = nil
            print("Cancelled recognition task")
        }
        
        audioEngine = nil
        isListening = false
        isSpeechDetected = false
        
        print("Speech recognition stopped and all resources cleaned up")
    }
    
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
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
            print("🎙️ Updated pause detection threshold to: \(threshold) seconds")
            
            if isListening && silenceTimer != nil {
                resetSilenceTimer()
            }
        }
    }
}
