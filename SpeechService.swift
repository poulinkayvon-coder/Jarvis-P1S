import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var transcript = ""
    @Published var wakeDetected = false
    @Published var lastError: String?

    var onCommand: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var commandDebounceTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var shouldKeepListening = false
    private var lastDeliveredCommand = ""

    private let wakePhrase = "hey jarvis"

    func start() async throws {
        shouldKeepListening = true
        try await ensurePermissions()
        try beginRecognitionSession()
    }

    func startAlwaysListening() async throws {
        if isListening { return }
        try await start()
    }

    func stop() {
        shouldKeepListening = false
        restartTask?.cancel()
        commandDebounceTask?.cancel()
        stopRecognitionSession()
        wakeDetected = false
        transcript = ""
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
        guard shouldKeepListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "JarvisSpeech", code: 4, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is unavailable."])
        }

        stopRecognitionSession(keepListeningState: true)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
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

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let spoken = result.bestTranscription.formattedString
                    self.transcript = spoken
                    self.processTranscript(spoken)

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

    private func processTranscript(_ spoken: String) {
        let lowered = spoken.lowercased()

        if !wakeDetected {
            guard let wakeRange = lowered.range(of: wakePhrase) else { return }
            wakeDetected = true

            let suffixStart = wakeRange.upperBound
            let suffix = String(spoken[suffixStart...])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))

            if !suffix.isEmpty {
                scheduleCommandDelivery(suffix)
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
            scheduleCommandDelivery(cleaned)
        }
    }

    private func scheduleCommandDelivery(_ command: String) {
        commandDebounceTask?.cancel()
        commandDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(950))
            guard !Task.isCancelled else { return }
            guard let self else { return }

            let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            guard cleaned.caseInsensitiveCompare(self.lastDeliveredCommand) != .orderedSame else { return }

            self.lastDeliveredCommand = cleaned
            self.wakeDetected = false
            self.transcript = ""
            self.onCommand?(cleaned)
            self.scheduleRecognitionRestart(delayMilliseconds: 250)
        }
    }

    private func scheduleRecognitionRestart(delayMilliseconds: Int = 450) {
        guard shouldKeepListening else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            guard let self, self.shouldKeepListening else { return }

            do {
                try self.beginRecognitionSession()
            } catch {
                self.lastError = error.localizedDescription
                self.isListening = false
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
}
