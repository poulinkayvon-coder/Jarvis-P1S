import Foundation
import Combine

@MainActor
final class JarvisAppModel: ObservableObject {
    @Published var messages: [(String, Bool)] = [("Good evening. Jarvis is online.", false)]
    @Published var status = PrinterStatus()
    @Published var ams = AMSState()
    @Published var isBusy = false

    let speech = SpeechService()
    private let parser = CommandParser()
    private let modelProvider: ModelProvider = UnconfiguredModelProvider()
    private var printer: PrinterTransport?

    init() {
        if let host = UserDefaults.standard.string(forKey: "p1s.host"),
           let code = Keychain.get("p1s.accessCode") {
            printer = BambuP1STransport(host: host, accessCode: code)
        }
    }

    func handle(_ text: String) {
        messages.append((text, true))
        switch parser.parse(text) {
        case .status: Task { await getStatus() }
        case .pause: Task { await printerAction { try await self.printer?.pause() } }
        case .resume: Task { await printerAction { try await self.printer?.resume() } }
        case .cancel: Task { await printerAction { try await self.printer?.cancel() } }
        case .findAndPrint(let query, let color, let slot):
            Task { await findProfile(query: query, color: color, slot: slot) }
        case .unknown:
            messages.append(("Try “print a Benchy in red using slot 3.”", false))
        }
    }

    private func getStatus() async {
        guard let printer else {
            messages.append(("Your P1S isn't configured yet.", false))
            return
        }
        do {
            status = try await printer.status()
            messages.append(("The printer is \(status.state.rawValue).", false))
        } catch {
            messages.append(("I couldn't read the P1S: \(error.localizedDescription)", false))
        }
    }

    private func findProfile(query: String, color: String?, slot: Int?) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let results = try await modelProvider.searchPrintProfiles(
                query: query,
                printer: "Bambu Lab P1S",
                nozzle: "0.4 mm",
                material: "PLA"
            )
            guard let best = results.first else {
                messages.append(("I couldn't find a P1S-compatible sliced 3MF for \(query).", false))
                return
            }
            messages.append(("I found “\(best.name)” from \(best.source). Requested color: \(color ?? "profile default"). Requested AMS slot: \(slot.map(String.init) ?? "automatic").", false))
        } catch {
            messages.append(("3MF search isn't configured yet: \(error.localizedDescription)", false))
        }
    }

    private func printerAction(_ action: @escaping () async throws -> Void) async {
        do {
            try await action()
            messages.append(("Done.", false))
        } catch {
            messages.append(("I couldn't complete that printer command: \(error.localizedDescription)", false))
        }
    }
}
