import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isListening = false
    @Published var isAwake = false
    @Published var isSpeaking = false
    @Published var transcript = ""
    @Published var statusText = "VOICE LINK STANDBY"
    @Published var lastError: String?

    var onCommand: ((String) -> Void)?
    let wakePhrase = "hey jarvis"

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let synthesizer = AVSpeechSynthesizer()

    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var commandDebounceTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var shouldKeepListening = false
    private var restartAfterSpeech = false
    private var lastDeliveredCommand = ""

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start() async throws {
        try await startAlwaysListening()
    }

    func startAlwaysListening() async throws {
        shouldKeepListening = true
        try await ensurePermissions()
        if !isListening && !isSpeaking {
            try beginRecognitionSession()
        }
        statusText = "LISTENING FOR “HEY JARVIS”"
    }

    func stop() {
        shouldKeepListening = false
        restartTask?.cancel()
        commandDebounceTask?.cancel()
        stopRecognitionSession()
        isAwake = false
        transcript = ""
        statusText = "VOICE LINK STANDBY"
    }

    func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        restartAfterSpeech = shouldKeepListening
        restartTask?.cancel()
        commandDebounceTask?.cancel()
        stopRecognitionSession()

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        isSpeaking = true
        statusText = "JARVIS SPEAKING"
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = preferredJarvisVoice()
        utterance.rate = 0.48
        utterance.pitchMultiplier = 0.9
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    private func preferredJarvisVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        return voices.first { $0.language.lowercased().hasPrefix("en-gb") && $0.quality == .enhanced }
            ?? voices.first { $0.language.lowercased().hasPrefix("en-gb") }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func ensurePermissions() async throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "JarvisSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is unavailable."])
        }

        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authorization == .authorized else {
            throw NSError(domain: "JarvisSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission was not granted."])
        }

        let microphonePermission = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard microphonePermission else {
            throw NSError(domain: "JarvisSpeech", code: 3, userInfo: [NSLocalizedDescriptionKey: "Microphone permission was not granted."])
        }
    }

    private func beginRecognitionSession() throws {
        guard shouldKeepListening, !isSpeaking else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "JarvisSpeech", code: 4, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is unavailable."])
        }

        stopRecognitionSession(keepListeningState: true)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionRequest = request

        let node = engine.inputNode
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isListening = true
        lastError = nil
        statusText = isAwake ? "LISTENING" : "LISTENING FOR “HEY JARVIS”"

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let spoken = result.bestTranscription.formattedString
                    self.transcript = spoken
                    self.processTranscript(spoken, final: result.isFinal)
                    if result.isFinal {
                        self.scheduleRecognitionRestart()
                    }
                }

                if let error {
                    self.lastError = error.localizedDescription
                    self.scheduleRecognitionRestart()
                }
            }
        }
    }

    private func processTranscript(_ spoken: String, final: Bool) {
        let lowered = spoken.lowercased()

        if !isAwake {
            guard let wakeRange = lowered.range(of: wakePhrase) else { return }
            isAwake = true
            statusText = "YES?"

            let suffixStart = wakeRange.upperBound
            let suffix = String(spoken[suffixStart...])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))

            if !suffix.isEmpty {
                scheduleCommandDelivery(suffix, immediate: final)
            } else {
                transcript = ""
                scheduleRecognitionRestart(delayMilliseconds: 150, preserveAwake: true)
            }
            return
        }

        let commandText: String
        if let wakeRange = lowered.range(of: wakePhrase) {
            commandText = String(spoken[wakeRange.upperBound...])
        } else {
            commandText = spoken
        }

        let cleaned = commandText
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if !cleaned.isEmpty {
            scheduleCommandDelivery(cleaned, immediate: final)
        }
    }

    private func scheduleCommandDelivery(_ command: String, immediate: Bool = false) {
        commandDebounceTask?.cancel()
        commandDebounceTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(850))
            }
            guard !Task.isCancelled, let self else { return }

            let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            guard cleaned.caseInsensitiveCompare(self.lastDeliveredCommand) != .orderedSame else { return }

            self.lastDeliveredCommand = cleaned
            self.isAwake = false
            self.transcript = ""
            self.statusText = "PROCESSING"
            self.onCommand?(cleaned)
        }
    }

    private func scheduleRecognitionRestart(delayMilliseconds: Int = 400, preserveAwake: Bool = false) {
        guard shouldKeepListening, !isSpeaking else { return }
        let awakeState = preserveAwake ? isAwake : false
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self, self.shouldKeepListening, !self.isSpeaking else { return }
            self.stopRecognitionSession(keepListeningState: true)
            self.isAwake = awakeState
            do {
                try self.beginRecognitionSession()
            } catch {
                self.lastError = error.localizedDescription
                self.isListening = false
                self.statusText = "VOICE LINK ERROR"
            }
        }
    }

    private func stopRecognitionSession(keepListeningState: Bool = false) {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)

        if !keepListeningState {
            isListening = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        if restartAfterSpeech {
            restartAfterSpeech = false
            scheduleRecognitionRestart(delayMilliseconds: 300)
        } else {
            statusText = "VOICE LINK STANDBY"
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        if restartAfterSpeech {
            restartAfterSpeech = false
            scheduleRecognitionRestart(delayMilliseconds: 300)
        }
    }
}
