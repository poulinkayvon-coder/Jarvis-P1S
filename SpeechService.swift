import Foundation
import Speech
@preconcurrency import AVFoundation
import Combine

struct JarvisVoiceChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let quality: String

    var label: String {
        "\(name) • \(language) • \(quality)"
    }
}

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isListening = false
    @Published var isAwake = false
    @Published var isSpeaking = false
    @Published var transcript = ""
    @Published var statusText = "VOICE LINK STANDBY"
    @Published var lastError: String?
    @Published var selectedVoiceIdentifier: String

    var onCommand: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let synthesizer = AVSpeechSynthesizer()

    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var commandDebounceTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var conversationTimeoutTask: Task<Void, Never>?
    private var shouldKeepListening = false
    private var restartAfterSpeech = false
    private var conversationUntil: Date?
    private var lastDeliveredCommand = ""
    private var lastDeliveredAt = Date.distantPast

    private let wakeAliases = [
        "hey jarvis", "hey jervis", "okay jarvis", "ok jarvis", "yo jarvis",
        "jarvis", "jervis", "jarvus"
    ]

    override init() {
        let stored = UserDefaults.standard.string(forKey: "jarvis.voice.identifier")
        selectedVoiceIdentifier = stored ?? ""
        super.init()
        synthesizer.delegate = self

        if selectedVoiceIdentifier.isEmpty,
           let preferred = preferredJarvisVoice() {
            selectedVoiceIdentifier = preferred.identifier
            UserDefaults.standard.set(preferred.identifier, forKey: "jarvis.voice.identifier")
        }
    }

    var availableVoiceChoices: [JarvisVoiceChoice] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }

        return voices
            .sorted { lhs, rhs in
                let l = voiceRank(lhs)
                let r = voiceRank(rhs)
                if l == r { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
                return l > r
            }
            .prefix(18)
            .map {
                JarvisVoiceChoice(
                    id: $0.identifier,
                    name: $0.name,
                    language: $0.language,
                    quality: qualityName($0.quality)
                )
            }
    }

    func selectVoice(identifier: String) {
        selectedVoiceIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: "jarvis.voice.identifier")
    }

    func previewVoice() {
        speak("At your service. Voice interface online.")
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
        updateListeningStatus()
    }

    func restartVoiceLink() {
        shouldKeepListening = true
        restartTask?.cancel()
        commandDebounceTask?.cancel()
        stopRecognitionSession()
        Task {
            do {
                try await startAlwaysListening()
            } catch {
                lastError = error.localizedDescription
                statusText = "VOICE LINK ERROR"
            }
        }
    }

    func stop() {
        shouldKeepListening = false
        restartTask?.cancel()
        commandDebounceTask?.cancel()
        conversationTimeoutTask?.cancel()
        conversationUntil = nil
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
        utterance.voice = currentVoice()
        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.02
        utterance.postUtteranceDelay = 0.04
        synthesizer.speak(utterance)
    }

    private func currentVoice() -> AVSpeechSynthesisVoice? {
        if !selectedVoiceIdentifier.isEmpty,
           let selected = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
            return selected
        }
        return preferredJarvisVoice()
    }

    private func preferredJarvisVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let preferredNames = ["Daniel", "Arthur", "Oliver", "Jamie", "Alex"]

        for name in preferredNames {
            if let voice = voices.first(where: {
                $0.name.localizedCaseInsensitiveContains(name) &&
                $0.language.lowercased().hasPrefix("en-gb") &&
                $0.quality != .default
            }) {
                return voice
            }
        }

        return voices.first {
            $0.language.lowercased().hasPrefix("en-gb") && $0.quality == .premium
        } ?? voices.first {
            $0.language.lowercased().hasPrefix("en-gb") && $0.quality == .enhanced
        } ?? voices.first {
            $0.language.lowercased().hasPrefix("en-gb")
        } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func voiceRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0
        if voice.language.lowercased().hasPrefix("en-gb") { score += 100 }
        if voice.quality == .premium { score += 30 }
        if voice.quality == .enhanced { score += 20 }
        let preferredNames = ["Daniel", "Arthur", "Oliver", "Jamie", "Alex"]
        if preferredNames.contains(where: { voice.name.localizedCaseInsensitiveContains($0) }) { score += 40 }
        return score
    }

    private func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
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
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["Jarvis", "Hey Jarvis", "Bambu Lab", "MakerWorld", "P1S", "AMS"]
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionRequest = request

        let node = engine.inputNode
        node.removeTap(onBus: 0)
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "JarvisSpeech", code: 5, userInfo: [NSLocalizedDescriptionKey: "The microphone audio format is unavailable."])
        }

        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isListening = true
        lastError = nil
        updateListeningStatus()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let spoken = result.bestTranscription.formattedString
                    self.transcript = spoken
                    self.processTranscript(spoken, final: result.isFinal)
                    if result.isFinal {
                        self.scheduleRecognitionRestart(
                            delayMilliseconds: 180,
                            preserveAwake: self.conversationIsActive
                        )
                    }
                }

                if let error {
                    self.lastError = error.localizedDescription
                    self.scheduleRecognitionRestart(
                        delayMilliseconds: 350,
                        preserveAwake: self.conversationIsActive
                    )
                }
            }
        }
    }

    private var conversationIsActive: Bool {
        guard let until = conversationUntil else { return false }
        return until > Date()
    }

    private func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " ? Character(String(scalar)) : " "
        }
        return String(allowed)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func wakeMatch(in spoken: String) -> (normalized: String, alias: String, range: Range<String.Index>)? {
        let clean = normalized(spoken)
        for alias in wakeAliases.sorted(by: { $0.count > $1.count }) {
            if let range = clean.range(of: alias) {
                return (clean, alias, range)
            }
        }
        return nil
    }

    private func processTranscript(_ spoken: String, final: Bool) {
        if !conversationIsActive && isAwake {
            endConversationMode()
        }

        if !isAwake {
            guard let match = wakeMatch(in: spoken) else { return }
            beginConversationMode()
            statusText = "YES?"

            let suffix = String(match.normalized[match.range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !suffix.isEmpty {
                scheduleCommandDelivery(suffix, immediate: final)
            } else {
                transcript = ""
                scheduleRecognitionRestart(delayMilliseconds: 120, preserveAwake: true)
            }
            return
        }

        let clean = normalized(spoken)
        var commandText = clean
        if let match = wakeMatch(in: spoken) {
            commandText = String(match.normalized[match.range.upperBound...])
        }

        let cleaned = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        extendConversationMode()
        scheduleCommandDelivery(cleaned, immediate: final)
    }

    private func beginConversationMode() {
        isAwake = true
        extendConversationMode()
    }

    private func extendConversationMode() {
        conversationUntil = Date().addingTimeInterval(15)
        conversationTimeoutTask?.cancel()
        conversationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.endConversationMode()
        }
    }

    private func endConversationMode() {
        conversationUntil = nil
        conversationTimeoutTask?.cancel()
        isAwake = false
        transcript = ""
        updateListeningStatus()
    }

    private func scheduleCommandDelivery(_ command: String, immediate: Bool = false) {
        commandDebounceTask?.cancel()
        commandDebounceTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(650))
            }
            guard !Task.isCancelled, let self else { return }

            let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }

            let duplicateTooSoon = cleaned.caseInsensitiveCompare(self.lastDeliveredCommand) == .orderedSame &&
                Date().timeIntervalSince(self.lastDeliveredAt) < 2.0
            guard !duplicateTooSoon else { return }

            self.lastDeliveredCommand = cleaned
            self.lastDeliveredAt = Date()
            self.transcript = ""
            self.statusText = "PROCESSING"
            self.extendConversationMode()
            self.onCommand?(cleaned)
        }
    }

    private func scheduleRecognitionRestart(delayMilliseconds: Int = 350, preserveAwake: Bool = false) {
        guard shouldKeepListening, !isSpeaking else { return }
        let keepConversation = preserveAwake && conversationIsActive
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self, self.shouldKeepListening, !self.isSpeaking else { return }
            self.stopRecognitionSession(keepListeningState: true)
            self.isAwake = keepConversation
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

    private func updateListeningStatus() {
        guard shouldKeepListening else {
            statusText = "VOICE LINK STANDBY"
            return
        }
        if isSpeaking {
            statusText = "JARVIS SPEAKING"
        } else if isAwake && conversationIsActive {
            statusText = "CONVERSATION ACTIVE"
        } else if isListening {
            statusText = "LISTENING FOR JARVIS"
        } else {
            statusText = "VOICE LINK CONNECTING"
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speechDidEnd()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speechDidEnd()
        }
    }

    private func speechDidEnd() {
        isSpeaking = false
        if restartAfterSpeech {
            restartAfterSpeech = false
            scheduleRecognitionRestart(
                delayMilliseconds: 220,
                preserveAwake: conversationIsActive
            )
        } else {
            updateListeningStatus()
        }
    }
}
