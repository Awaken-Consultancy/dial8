import Foundation
import AVFoundation
import Combine

class AudioRecordingService: ObservableObject {
    // Published properties for state
    @Published private(set) var isRecording = false
    @Published private(set) var isStoppingRecording = false
    @Published var recordingStartTime: Date?
    
    // Audio recording components
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?
    private let writeQueue = DispatchQueue(label: "com.dial8.audio.write")
    
    // Dependencies
    private let audioEngineService: AudioEngineService
    
    init(audioEngineService: AudioEngineService) {
        self.audioEngineService = audioEngineService
    }
    
    func beginRecording() {
        print("AudioRecordingService: Beginning recording using AudioEngine buffer")
        
        // Initialize recording start time
        self.recordingStartTime = Date()
        print("⏱️ Recording start time initialized")
        
        let tempDir = FileManager.default.temporaryDirectory
        self.audioFileURL = tempDir.appendingPathComponent("recording_\(UUID().uuidString).wav")

        guard let url = self.audioFileURL else { return }

        // Setup the audio file for writing
        // We expect 16kHz, mono, float32 from AudioEngineService
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            self.audioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            self.isRecording = true
            print("Recording started successfully with single audio engine source")
        } catch {
            print("Failed to create audio file: \(error)")
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
    }
    
    func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        // Check atomic property first to avoid queue overhead if not recording
        guard isRecording else { return }
        
        writeQueue.async { [weak self] in
            guard let self = self, self.isRecording, let audioFile = self.audioFile else { return }
            
            do {
                try audioFile.write(from: buffer)
            } catch {
                print("AudioRecordingService: Failed to write buffer: \(error)")
            }
        }
    }
    
    func stopRecording(withFinalProcessing: Bool = true, completion: @escaping (URL?) -> Void) {
        guard isRecording else { 
            completion(nil)
            return 
        }
        
        print("⏹️ Stopping recording...")
        
        // Set the stopping flag immediately
        self.isStoppingRecording = true
        
        // Update state
        DispatchQueue.main.async {
            self.isRecording = false
        }
        
        // Perform cleanup on the write queue to ensure all buffers are written
        writeQueue.async { [weak self] in
            guard let self = self else { 
                completion(nil)
                return 
            }
            
            // Close file by releasing reference
            self.audioFile = nil
            
            let fileURL = self.audioFileURL
            
            // Reset state
            DispatchQueue.main.async {
                self.isStoppingRecording = false
                self.audioFileURL = nil
                
                // Return the file URL for processing if needed
                completion(withFinalProcessing ? fileURL : nil)
                
                // If not processing the file, clean it up
                if !withFinalProcessing, let fileURL = fileURL {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }
    
    func startNewAudioSegment() -> URL? {
        print("Starting new audio segment...")
        
        let tempDir = FileManager.default.temporaryDirectory
        let newAudioFileURL = tempDir.appendingPathComponent("recording_\(UUID().uuidString).wav")
        
        // Capture old file URL to return
        let oldFileURL = self.audioFileURL
        
        // We need to synchronize the file swap on the write queue
        // But we need to return the URL synchronously to the caller?
        // startNewAudioSegment is typically called from MainActor (UI or Logic).
        // Since we cannot return synchronously if we dispatch async, we will have to be careful.
        
        // Ideally we pause writing, swap, resume.
        // However, given the method signature returns URL?, we have to do it somewhat synchronously or assume safety.
        // Let's use sync on writeQueue to safely swap.
        
        var success = false
        
        writeQueue.sync {
            // Close old file (it gets closed when we overwrite audioFile, but we want to be explicit if we were holding a ref)
            // Actually, we just create the new one and replace the reference.
            
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            
            do {
                let newFile = try AVAudioFile(forWriting: newAudioFileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                
                // Swap
                self.audioFile = newFile
                self.audioFileURL = newAudioFileURL
                DispatchQueue.main.async {
                    self.recordingStartTime = Date()
                }
                
                print("Started new audio segment recording seamlessly")
                success = true
                
            } catch {
                print("Failed to start new audio segment: \(error)")
                success = false
            }
        }
        
        return success ? oldFileURL : nil
    }
    
    func cleanupTempFile(at url: URL?) {
        guard let url = url else { return }
        
        do {
            try FileManager.default.removeItem(at: url)
            print("Cleaned up temporary audio file at: \(url.lastPathComponent)")
        } catch {
            print("Failed to clean up temporary file: \(error)")
        }
    }
}
