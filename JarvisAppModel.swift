import Foundation
import Combine

@MainActor
final class JarvisAppModel: ObservableObject {
    @Published var messages: [(String, Bool)] = [("Good evening. Jarvis is online.", false)]
    @Published var status = PrinterStatus()
    @Published var ams = AMSState()
    @Published var isBusy = false
    @Published var showSetup = false
    @Published var pendingPrintName: String?

    let speech = SpeechService()
    private let parser = CommandParser()
    private let modelProvider: ModelProvider = MakerWorldProvider()
    private var printer: PrinterTransport?
    private var pendingPrint: PendingPrint?

    private struct PendingPrint {
        let candidate: ModelCandidate
        let requestedColor: String?
        let requestedSlot: Int?
    }

    var configured: Bool {
        UserDefaults.standard.string(forKey: "p1s.host") != nil &&
        UserDefaults.standard.string(forKey: "p1s.serial") != nil &&
        Keychain.get("p1s.accessCode") != nil
    }

    init() {
        rebuildPrinter()
        if !configured {
            showSetup = true
        } else {
            Task { await getStatus(showSuccessMessage: false) }
        }
    }

    func configure(host: String, serial: String, accessCode: String) {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSerial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(cleanHost, forKey: "p1s.host")
        UserDefaults.standard.set(cleanSerial, forKey: "p1s.serial")
        Keychain.set(cleanCode, for: "p1s.accessCode")
        rebuildPrinter()
        status = PrinterStatus()
        messages.append(("P1S connection saved. Testing the local connection…", false))
        Task { await getStatus(showSuccessMessage: true) }
    }

    private func rebuildPrinter() {
        guard let host = UserDefaults.standard.string(forKey: "p1s.host"),
              let serial = UserDefaults.standard.string(forKey: "p1s.serial"),
              let code = Keychain.get("p1s.accessCode"),
              !host.isEmpty, !serial.isEmpty, !code.isEmpty else {
            printer = nil
            return
        }
        printer = BambuP1STransport(host: host, serial: serial, accessCode: code)
    }

    func handle(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        messages.append((clean, true))

        if pendingPrint != nil {
            let lower = clean.lowercased()
            if ["yes", "yeah", "yep", "confirm", "do it", "print it", "start it"].contains(where: lower.contains) {
                Task { await confirmPendingPrint() }
                return
            }
            if ["no", "nope", "cancel", "don't", "do not", "never mind", "nevermind"].contains(where: lower.contains) {
                cancelPendingPrint()
                return
            }
            messages.append(("I found a print and I'm waiting for your confirmation. Say yes to print it or no to cancel.", false))
            return
        }

        guard configured else {
            messages.append(("I need your P1S connection details first. Open Setup and enter the printer IP, serial number, and LAN access code.", false))
            showSetup = true
            return
        }

        switch parser.parse(clean) {
        case .status: Task { await getStatus(showSuccessMessage: true) }
        case .pause: Task { await printerAction("pause") { try await self.requirePrinter().pause() } }
        case .resume: Task { await printerAction("resume") { try await self.requirePrinter().resume() } }
        case .cancel: Task { await printerAction("stop") { try await self.requirePrinter().cancel() } }
        case .findAndPrint(let query, let color, let slot):
            Task { await searchForPrint(query: query, color: color, slot: slot) }
        case .unknown:
            messages.append(("Try “print a Benchy in red using slot 3.” I'll search online, show you what I found, and wait for your confirmation before printing.", false))
        }
    }

    func confirmPendingPrint() async {
        guard !isBusy, let pending = pendingPrint else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            messages.append(("Confirmed. Downloading \(pending.candidate.name)…", false))
            let fileURL = try await modelProvider.download(profile: pending.candidate)
            let chosenSlot = pending.requestedSlot ?? 1
            guard (1...4).contains(chosenSlot) else {
                messages.append(("AMS slots are 1 through 4.", false))
                clearPendingPrint()
                return
            }

            let mapping = [FilamentMapping(
                id: UUID().uuidString,
                printFilamentID: "0",
                amsSlot: chosenSlot,
                confidence: pending.requestedColor == nil ? 0.7 : 0.95
            )]

            messages.append(("Sending \(pending.candidate.name) to the P1S using AMS slot \(chosenSlot)\(pending.requestedColor.map { " (\($0))" } ?? "")…", false))
            let p = try requirePrinter()
            try await p.uploadAndStart(fileURL: fileURL, displayName: pending.candidate.name, mappings: mapping)
            messages.append(("Print command sent to the P1S.", false))
            clearPendingPrint()
        } catch {
            messages.append(("I couldn't complete that print: \(error.localizedDescription)", false))
        }
    }

    func cancelPendingPrint() {
        guard pendingPrint != nil else { return }
        clearPendingPrint()
        messages.append(("Okay. I cancelled that print before sending anything to the P1S.", false))
    }

    private func clearPendingPrint() {
        pendingPrint = nil
        pendingPrintName = nil
    }

    private func requirePrinter() throws -> PrinterTransport {
        guard let printer else { throw JarvisError.notConfigured("P1S connection") }
        return printer
    }

    private func getStatus(showSuccessMessage: Bool) async {
        guard !isBusy else { return }
        guard let host = UserDefaults.standard.string(forKey: "p1s.host"),
              let serial = UserDefaults.standard.string(forKey: "p1s.serial"),
              let code = Keychain.get("p1s.accessCode"),
              !host.isEmpty, !serial.isEmpty, !code.isEmpty else {
            messages.append(("P1S connection details are incomplete. Open Setup and check them.", false))
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let probe = P1SStatusProbe(host: host, serial: serial, accessCode: code)
            let newStatus = try await probe.fetchStatus()
            status = newStatus
            if showSuccessMessage {
                messages.append(("P1S connected. Printer state: \(newStatus.state.rawValue). \(Int(newStatus.progress))% complete.", false))
            }
        } catch {
            status = PrinterStatus(state: .offline, errorMessage: error.localizedDescription)
            messages.append(("P1S connection failed: \(error.localizedDescription)", false))
        }
    }

    private func searchForPrint(query: String, color: String?, slot: Int?) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            messages.append(("Searching MakerWorld for a P1S-ready \(query)…", false))
            let results = try await modelProvider.searchPrintProfiles(
                query: query,
                printer: "Bambu Lab P1S",
                nozzle: "0.4 mm",
                material: "PLA"
            )
            guard let best = results.first else {
                messages.append(("I couldn't find a usable MakerWorld result for “\(query)”. Try a more specific name.", false))
                return
            }

            pendingPrint = PendingPrint(candidate: best, requestedColor: color, requestedSlot: slot)
            pendingPrintName = best.name
            let slotText = slot.map { " using AMS slot \($0)" } ?? ""
            let colorText = color.map { " in \($0)" } ?? ""
            messages.append(("I found “\(best.name)” on MakerWorld\(colorText)\(slotText). I have NOT sent anything to the printer. Do you want me to download and print it?", false))
        } catch {
            messages.append(("Online model search failed: \(error.localizedDescription)", false))
        }
    }

    private func printerAction(_ name: String, _ action: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await action()
            messages.append(("P1S \(name) command sent.", false))
        } catch {
            messages.append(("I couldn't send the \(name) command: \(error.localizedDescription)", false))
        }
    }
}
