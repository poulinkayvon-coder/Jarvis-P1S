import Foundation
import Speech
@preconcurrency import AVFoundation
import Combine
import KokoroSwift
import MLX
import MLXUtilsLibrary

struct JarvisVoiceChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let quality: String

    var label: String { "\(name) • \(language) • \(quality)" }
}

private actor NeuralVoiceEngine {
    private var kokoro: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    func isReady() -> Bool {
        kokoro != nil && !voices.isEmpty
    }

    func prepare(modelURL: URL, voicesURL: URL) throws {
        if isReady() { return }
        let loadedVoices = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
        guard !loadedVoices.isEmpty else {
            throw NSError(domain: "JarvisNeuralVoice", code: 11, userInfo: [NSLocalizedDescriptionKey: "The neural voice style file could not be read."])
        }
        voices = loadedVoices
        kokoro = KokoroTTS(modelPath: modelURL)
    }

    func generate(text: String, voiceIdentifier: String) throws -> [Float] {
        guard let kokoro else {
            throw NSError(domain: "JarvisNeuralVoice", code: 12, userInfo: [NSLocalizedDescriptionKey: "Natural voice engine is unavailable."])
        }
        let key = voiceIdentifier + ".npy"
        guard let voice = voices[key] ?? voices["bm_george.npy"] else {
            throw NSError(domain: "JarvisNeuralVoice", code: 13, userInfo: [NSLocalizedDescriptionKey: "Selected natural voice was not found."])
        }
        let (audio, _) = try kokoro.generateAudio(voice: voice, language: .enGB, text: text)
        return audio
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
    @Published var neuralVoiceStatus = "Natural voice preparing"
    @Published private(set) var isStarting = false

    var onCommand: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let synthesizer = AVSpeechSynthesizer()

    private let neuralAudioEngine = AVAudioEngine()
    private let neuralPlayer = AVAudioPlayerNode()
    private let neuralEngine = NeuralVoiceEngine()
    private var neuralPreparationTask: Task<Void, Never>?
    private var isPreparingNeuralVoice = false

    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionSessionID = UUID()
    private var hasInputTap = false
    private var commandDebounceTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var conversationTimeoutTask: Task<Void, Never>?
    private var shouldKeepListening = false
    private var restartAfterSpeech = false
    private var conversationUntil: Date?
    private var lastDeliveredCommand = ""
    private var lastDeliveredAt = Date.distantPast
    private var speechGenerationID = UUID()
    private var activeFallbackUtterance: AVSpeechUtterance?

    private let wakeAliases = [
        "hey jarvis", "hey jervis", "okay jarvis", "ok jarvis", "yo jarvis",
        "jarvis", "jervis", "jarvus"
    ]

    private let neuralVoiceChoices = [
        JarvisVoiceChoice(id: "bm_george", name: "George", language: "British English", quality: "Neural"),
        JarvisVoiceChoice(id: "bm_daniel", name: "Daniel", language: "British English", quality: "Neural"),
        JarvisVoiceChoice(id: "bm_lewis", name: "Lewis", language: "British English", quality: "Neural"),
        JarvisVoiceChoice(id: "bm_fable", name: "Fable", language: "British English", quality: "Neural")
    ]

    override init() {
        let stored = UserDefaults.standard.string(forKey: "jarvis.voice.identifier")
        selectedVoiceIdentifier = stored.flatMap { $0.hasPrefix("bm_") ? $0 : nil } ?? "bm_george"
        super.init()
        synthesizer.delegate = self
        neuralAudioEngine.attach(neuralPlayer)
        UserDefaults.standard.set(selectedVoiceIdentifier, forKey: "jarvis.voice.identifier")
        neuralVoiceStatus = neuralFilesExist ? "Natural voice files ready" : "Natural voice not downloaded"
    }

    var availableVoiceChoices: [JarvisVoiceChoice] { neuralVoiceChoices }

    func selectVoice(identifier: String) {
        guard neuralVoiceChoices.contains(where: { $0.id == identifier }) else { return }
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
        if isListening || isStarting || isSpeaking {
            updateListeningStatus()
            return
        }

        isStarting = true
        statusText = "VOICE LINK CONNECTING"
        defer { isStarting = false }

        try await ensurePermissions()
        guard shouldKeepListening, !isSpeaking else { return }
        try beginRecognitionSession()
        updateListeningStatus()
    }

    func prepareNaturalVoice() {
        guard neuralPreparationTask == nil else { return }
        neuralPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareKokoroIfNeeded(updateMainStatus: false)
            } catch {
                self.lastError = "Natural voice: \(error.localizedDescription)"
                self.neuralVoiceStatus = "Natural voice unavailable"
            }
            self.neuralPreparationTask = nil
        }
    }

    func restartVoiceLink() {
        shouldKeepListening = true
        restartTask?.cancel()
        commandDebounceTask?.cancel()
        stopRecognitionSession()
        isAwake = false
        transcript = ""
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startAlwaysListening()
            } catch {
                self.lastError = error.localizedDescription
                self.isListening = false
                self.statusText = "VOICE LINK ERROR"
            }
        }
    }

    func stop() {
        shouldKeepListening = false
        restartTask?.cancel()
        commandDebounceTask?.cancel()
        conversationTimeoutTask?.cancel()
        conversationUntil = nil
        speechGenerationID = UUID()
        activeFallbackUtterance = nil
        stopRecognitionSession()
        stopNeuralPlayback()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isAwake = false
        isSpeaking = false
        transcript = ""
        statusText = "VOICE LINK STANDBY"
    }

    func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let generationID = UUID()
        speechGenerationID = generationID
        activeFallbackUtterance = nil
        restartAfterSpeech = shouldKeepListening
        restartTask?.cancel()
        commandDebounceTask?.cancel()
        stopRecognitionSession()
        stopNeuralPlayback()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        isSpeaking = true
        statusText = "PREPARING NATURAL VOICE"

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.speakWithKokoro(clean, generationID: generationID)
            } catch {
                guard self.speechGenerationID == generationID else { return }
                self.lastError = "Natural voice: \(error.localizedDescription)"
                self.neuralVoiceStatus = "Natural voice unavailable — fallback active"
                self.speakWithSystemFallback(clean, generationID: generationID)
            }
        }
    }

    private var voiceDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JarvisNaturalVoice", isDirectory: true)
    }

    private var modelURL: URL { voiceDirectory.appendingPathComponent("kokoro-v1_0.safetensors") }
    private var voicesURL: URL { voiceDirectory.appendingPathComponent("voices.npz") }

    private var neuralFilesExist: Bool {
        FileManager.default.fileExists(atPath: modelURL.path) &&
        FileManager.default.fileExists(atPath: voicesURL.path)
    }

    private func prepareKokoroIfNeeded(updateMainStatus: Bool = true) async throws {
        if await neuralEngine.isReady() { return }

        if isPreparingNeuralVoice {
            while isPreparingNeuralVoice {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(150))
            }
            guard await neuralEngine.isReady() else {
                throw NSError(domain: "JarvisNeuralVoice", code: 10, userInfo: [NSLocalizedDescriptionKey: "Natural voice setup did not finish."])
            }
            return
        }

        isPreparingNeuralVoice = true
        defer { isPreparingNeuralVoice = false }
        try FileManager.default.createDirectory(at: voiceDirectory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: modelURL.path) {
            neuralVoiceStatus = "Downloading natural voice model (~327 MB)…"
            if updateMainStatus { statusText = "DOWNLOADING NATURAL VOICE" }
            try await downloadFile(
                from: URL(string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main/kokoro-v1_0.safetensors?download=true")!,
                to: modelURL
            )
        }

        if !FileManager.default.fileExists(atPath: voicesURL.path) {
            neuralVoiceStatus = "Downloading voice styles (~14 MB)…"
            if updateMainStatus { statusText = "DOWNLOADING VOICE STYLE" }
            try await downloadFile(
                from: URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz")!,
                to: voicesURL
            )
        }

        neuralVoiceStatus = "Loading natural voice…"
        if updateMainStatus { statusText = "LOADING NATURAL VOICE" }
        try await neuralEngine.prepare(modelURL: modelURL, voicesURL: voicesURL)
        neuralVoiceStatus = "Natural voice ready"
    }

    private func downloadFile(from remoteURL: URL, to destination: URL) async throws {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "JarvisNeuralVoice", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Voice download failed with HTTP \(http.statusCode)."])
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporaryURL, to: destination)
    }

    private func speakWithKokoro(_ text: String, generationID: UUID) async throws {
        try await prepareKokoroIfNeeded()
        guard speechGenerationID == generationID else { return }

        let audio = try await neuralEngine.generate(text: text, voiceIdentifier: selectedVoiceIdentifier)
        guard speechGenerationID == generationID else { return }

        let sampleRate = Double(KokoroTTS.Constants.samplingRate)
        guard !audio.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "JarvisNeuralVoice", code: 14, userInfo: [NSLocalizedDescriptionKey: "Could not create neural speech audio."])
        }

        buffer.frameLength = buffer.frameCapacity
        audio.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: source.count) }
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try session.setActive(true)

        if neuralAudioEngine.isRunning { neuralAudioEngine.stop() }
        neuralAudioEngine.disconnectNodeOutput(neuralPlayer)
        neuralAudioEngine.connect(neuralPlayer, to: neuralAudioEngine.mainMixerNode, format: format)
        neuralAudioEngine.prepare()
        try neuralAudioEngine.start()

        guard speechGenerationID == generationID else {
            stopNeuralPlayback()
            return
        }

        statusText = "JARVIS SPEAKING"
        neuralVoiceStatus = "Natural voice ready"
        neuralPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
            Task { @MainActor in self?.speechDidEnd(generationID: generationID) }
        }
        neuralPlayer.play()
    }

    private func stopNeuralPlayback() {
        if neuralPlayer.isPlaying { neuralPlayer.stop() }
        if neuralAudioEngine.isRunning { neuralAudioEngine.stop() }
    }

    private func speakWithSystemFallback(_ text: String, generationID: UUID) {
        guard speechGenerationID == generationID else { return }
        isSpeaking = true
        statusText = "JARVIS SPEAKING • FALLBACK"
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        activeFallbackUtterance = utterance
        synthesizer.speak(utterance)
    }

    private func ensurePermissions() async throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "JarvisSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is unavailable."])
        }

        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else {
            throw NSError(domain: "JarvisSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission was not granted."])
        }

        let microphonePermission = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
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
        let sessionID = UUID()
        recognitionSessionID = sessionID

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["Jarvis", "Hey Jarvis", "Bambu Lab", "MakerWorld", "P1S", "AMS"]
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "JarvisSpeech", code: 5, userInfo: [NSLocalizedDescriptionKey: "The microphone audio format is unavailable."])
        }

        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        hasInputTap = true
        engine.prepare()
        try engine.start()

        isListening = true
        lastError = nil
        updateListeningStatus()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self,
                      self.recognitionSessionID == sessionID,
                      self.shouldKeepListening,
                      !self.isSpeaking else { return }

                if let result {
                    let spoken = result.bestTranscription.formattedString
                    self.transcript = spoken
                    self.processTranscript(spoken, final: result.isFinal)
                    if result.isFinal {
                        self.scheduleRecognitionRestart(delayMilliseconds: 220, preserveAwake: self.conversationIsActive)
                    }
                }

                if let error {
                    let description = error.localizedDescription
                    if !description.localizedCaseInsensitiveContains("cancel") {
                        self.lastError = description
                    }
                    self.scheduleRecognitionRestart(delayMilliseconds: 500, preserveAwake: self.conversationIsActive)
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
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " ? Character(String(scalar)) : " "
        }
        return String(mapped).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func wakeMatch(in spoken: String) -> (normalized: String, range: Range<String.Index>)? {
        let clean = normalized(spoken)
        for alias in wakeAliases.sorted(by: { $0.count > $1.count }) {
            if let range = clean.range(of: alias) { return (clean, range) }
        }
        return nil
    }

    private func processTranscript(_ spoken: String, final: Bool) {
        if !conversationIsActive && isAwake { endConversationMode() }

        if !isAwake {
            guard let match = wakeMatch(in: spoken) else { return }
            beginConversationMode()
            statusText = "YES?"
            let suffix = String(match.normalized[match.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty {
                scheduleCommandDelivery(suffix, immediate: final)
            } else {
                transcript = ""
                scheduleRecognitionRestart(delayMilliseconds: 180, preserveAwake: true)
            }
            return
        }

        let clean = normalized(spoken)
        var commandText = clean
        if let match = wakeMatch(in: spoken) { commandText = String(match.normalized[match.range.upperBound...]) }
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
            if !immediate { try? await Task.sleep(for: .milliseconds(650)) }
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

    private func scheduleRecognitionRestart(delayMilliseconds: Int = 450, preserveAwake: Bool = false) {
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
        recognitionSessionID = UUID()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if engine.isRunning { engine.stop() }
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        if !keepListeningState { isListening = false }
    }

    private func updateListeningStatus() {
        guard shouldKeepListening else { statusText = "VOICE LINK STANDBY"; return }
        if isSpeaking { statusText = "JARVIS SPEAKING" }
        else if isAwake && conversationIsActive { statusText = "CONVERSATION ACTIVE" }
        else if isListening { statusText = "LISTENING FOR JARVIS" }
        else { statusText = "VOICE LINK CONNECTING" }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.activeFallbackUtterance === utterance else { return }
            self.activeFallbackUtterance = nil
            self.speechDidEnd(generationID: self.speechGenerationID)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.activeFallbackUtterance === utterance else { return }
            self.activeFallbackUtterance = nil
            self.speechDidEnd(generationID: self.speechGenerationID)
        }
    }

    private func speechDidEnd(generationID: UUID) {
        guard speechGenerationID == generationID, isSpeaking else { return }
        isSpeaking = false
        stopNeuralPlayback()
        if restartAfterSpeech {
            restartAfterSpeech = false
            scheduleRecognitionRestart(delayMilliseconds: 350, preserveAwake: conversationIsActive)
        } else {
            updateListeningStatus()
        }
    }
}
