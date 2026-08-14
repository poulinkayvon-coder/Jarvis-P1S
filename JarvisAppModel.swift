import Foundation
import Combine

@MainActor
final class JarvisAppModel: ObservableObject {
    @Published var messages: [(String, Bool)] = [("Good evening. Jarvis is online.", false)]
    @Published var status = PrinterStatus()
    @Published var ams = AMSState()
    @Published var isBusy = false
    @Published var showSetup = false
    @Published var showFileImporter = false

    let speech = SpeechService()
    private let parser = CommandParser()
    private let modelProvider: ModelProvider = Local3MFProvider()
    private var printer: PrinterTransport?

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

    func import3MF(_ url: URL) {
        do {
            let saved = try Local3MFProvider.importFile(from: url)
            messages.append(("Imported \(saved.lastPathComponent). Say “print \(saved.deletingPathExtension().lastPathComponent)” when you're ready.", false))
        } catch {
            messages.append(("I couldn't import that file: \(error.localizedDescription)", false))
        }
    }

    func handle(_ text: String) {
        messages.append((text, true))
        guard configured else {
            messages.append(("I need your P1S connection details first. Open Setup and enter the printer IP, serial number, and LAN access code.", false))
            showSetup = true
            return
        }

        switch parser.parse(text) {
        case .status: Task { await getStatus(showSuccessMessage: true) }
        case .pause: Task { await printerAction("pause") { try await self.requirePrinter().pause() } }
        case .resume: Task { await printerAction("resume") { try await self.requirePrinter().resume() } }
        case .cancel: Task { await printerAction("stop") { try await self.requirePrinter().cancel() } }
        case .findAndPrint(let query, let color, let slot):
            Task { await findAndPrint(query: query, color: color, slot: slot) }
        case .unknown:
            messages.append(("Try “print a Benchy in red using slot 3.” First import the sliced .gcode.3mf into Jarvis with Import 3MF.", false))
        }
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

    private func findAndPrint(query: String, color: String?, slot: Int?) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let results = try await modelProvider.searchPrintProfiles(query: query, printer: "Bambu Lab P1S", nozzle: "0.4 mm", material: "PLA")
            guard let best = results.first else {
                messages.append(("I couldn't find a sliced 3MF containing “\(query)” in Jarvis's local files. Import the .gcode.3mf first.", false))
                return
            }

            let fileURL = try await modelProvider.download(profile: best)
            let chosenSlot = slot ?? 1
            guard (1...4).contains(chosenSlot) else {
                messages.append(("AMS slots are 1 through 4.", false))
                return
            }

            let mapping = [FilamentMapping(id: UUID().uuidString, printFilamentID: "0", amsSlot: chosenSlot, confidence: color == nil ? 0.7 : 0.95)]
            messages.append(("Found \(best.name). Starting it on AMS slot \(chosenSlot)\(color.map { " (\($0))" } ?? "")…", false))
            let p = try requirePrinter()
            try await p.uploadAndStart(fileURL: fileURL, displayName: best.name, mappings: mapping)
            messages.append(("Print command sent to the P1S.", false))
        } catch {
            messages.append(("I couldn't start the print: \(error.localizedDescription)", false))
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
