import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var transcript = ""

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func start() async throws {
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

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let node = engine.inputNode
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }

        isListening = true
        engine.prepare()
        try engine.start()

        recognizer.recognitionTask(with: request) { [weak self] result, _ in
            Task { @MainActor in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                }
            }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isListening = false
    }
}
