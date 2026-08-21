import Foundation
import Combine
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class JarvisAppModel: ObservableObject {
    @Published var messages: [(String, Bool)] = [("Good evening. Jarvis is online.", false)]
    @Published var status = PrinterStatus()
    @Published var ams = AMSState()
    @Published var isBusy = false
    @Published var showSetup = false
    @Published var pendingPrintName: String?
    @Published var brainStatus = "INITIALIZING"
    @Published var memoryCount = 0

    let speech = SpeechService()
    private let parser = CommandParser()
    private let modelProvider: ModelProvider = MakerWorldProvider()
    private let brain = JarvisBrain()
    private var printer: PrinterTransport?
    private var pendingPrint: PendingPrint?
    private var memories: [String] = []
    private var didStartVoiceLink = false

    private struct PendingPrint {
        let candidate: ModelCandidate
        let requestedColor: String?
        let requestedSlot: Int?
    }

    var configured: Bool {
        guard let host = UserDefaults.standard.string(forKey: "p1s.host"),
              let serial = UserDefaults.standard.string(forKey: "p1s.serial"),
              let code = Keychain.get("p1s.accessCode") else { return false }
        return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var makerWorldSignedIn: Bool {
        guard let token = Keychain.get("bambu.cloudToken") else { return false }
        return !token.isEmpty
    }

    var makerWorldAccount: String {
        UserDefaults.standard.string(forKey: "bambu.account") ?? ""
    }

    init() {
        memories = UserDefaults.standard.stringArray(forKey: "jarvis.memories") ?? []
        memoryCount = memories.count

        speech.onCommand = { [weak self] command in
            self?.handle(command)
        }

        rebuildPrinter()
        brainStatus = brain.availabilityLabel

        if !configured {
            showSetup = true
        } else {
            Task { await getStatus(showSuccessMessage: false) }
        }
    }

    func startVoiceLinkIfNeeded() {
        guard !didStartVoiceLink else { return }
        didStartVoiceLink = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.speech.startAlwaysListening()
                self.reply("Voice link active. Say “Hey Jarvis” whenever you need me.", speak: false)
                self.speech.prepareNaturalVoice()
            } catch {
                self.didStartVoiceLink = false
                self.reply("Voice wake-up is unavailable: \(error.localizedDescription). You can still type commands.", speak: false)
            }
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
        ams = AMSState()
        reply("P1S connection saved. Testing the local connection…", speak: false)
        Task { await getStatus(showSuccessMessage: true) }
    }

    func signInMakerWorld(account: String, password: String, verificationCode: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await BambuCloudAuth.shared.login(
                account: account,
                password: password,
                verificationCode: verificationCode
            )
            reply(result.message, speak: false)
            objectWillChange.send()
        } catch {
            reply("MakerWorld sign-in failed: \(error.localizedDescription)", speak: false)
        }
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

        if handleMemoryCommand(clean) { return }

        if pendingPrint != nil {
            switch parser.parse(clean) {
            case .confirmPrint:
                Task { await confirmPendingPrint() }
            case .declinePrint, .cancel:
                cancelPendingPrint()
            default:
                reply("I have a print waiting for authorization. Say yes to print it or no to cancel.")
            }
            return
        }

        switch parser.parse(clean) {
        case .status:
            guardPrinterConfigured { Task { await self.getStatus(showSuccessMessage: true) } }
        case .pause:
            guardPrinterConfigured { Task { await self.printerAction("pause") { try await self.requirePrinter().pause() } } }
        case .resume:
            guardPrinterConfigured { Task { await self.printerAction("resume") { try await self.requirePrinter().resume() } } }
        case .cancel:
            guardPrinterConfigured { Task { await self.printerAction("stop") { try await self.requirePrinter().cancel() } } }
        case .findAndPrint(let query, let color, let slot):
            guardPrinterConfigured { Task { await self.searchForPrint(query: query, color: color, slot: slot) } }
        case .confirmPrint:
            reply("There isn't a pending model to confirm.")
        case .declinePrint:
            reply("There isn't a pending print to cancel.")
        case .unknown:
            Task { await generalConversation(clean) }
        }
    }

    private func guardPrinterConfigured(_ action: () -> Void) {
        guard configured else {
            reply("I need the P1S connection details first. Open Settings and add the printer IP, serial number, and LAN access code.")
            showSetup = true
            return
        }
        action()
    }

    private func handleMemoryCommand(_ text: String) -> Bool {
        let lower = text.lowercased()
        let rememberPrefixes = ["remember that ", "remember "]
        for prefix in rememberPrefixes where lower.hasPrefix(prefix) {
            let index = text.index(text.startIndex, offsetBy: prefix.count)
            let item = String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return false }
            memories.append(item)
            memories = Array(memories.suffix(40))
            saveMemories()
            reply("Understood. I'll remember that.")
            return true
        }

        if lower.contains("what do you remember") || lower.contains("what have you remembered") {
            if memories.isEmpty {
                reply("I don't have any saved memories yet.")
            } else {
                let summary = memories.suffix(8).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                reply("Here's what I currently remember:\n\(summary)", speak: false)
                speech.speak("I have \(memories.count) saved memories. They're displayed on screen.")
            }
            return true
        }

        if lower == "forget everything" || lower == "clear your memory" {
            memories.removeAll()
            saveMemories()
            reply("Memory cleared.")
            return true
        }

        return false
    }

    private func saveMemories() {
        UserDefaults.standard.set(memories, forKey: "jarvis.memories")
        memoryCount = memories.count
    }

    private func generalConversation(_ text: String) async {
        guard !isBusy else { return }
        isBusy = true
        brainStatus = "THINKING"
        defer {
            isBusy = false
            brainStatus = brain.availabilityLabel
        }

        do {
            let response = try await brain.respond(to: text, memories: memories)
            reply(response)
        } catch {
            reply("My on-device intelligence isn't available right now. Printer controls and voice commands are still online. \(error.localizedDescription)")
        }
    }

    func confirmPendingPrint() async {
        guard !isBusy, let pending = pendingPrint else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            reply("Confirmed. Downloading \(pending.candidate.name)…", speak: false)
            let fileURL = try await modelProvider.download(profile: pending.candidate)

            let chosenSlot: Int
            if let requestedSlot = pending.requestedSlot {
                chosenSlot = requestedSlot
            } else if let color = pending.requestedColor {
                if let cached = bestCachedSlot(for: color) {
                    chosenSlot = cached
                } else {
                    await refreshAMSState()
                    chosenSlot = bestCachedSlot(for: color) ?? 1
                }
            } else {
                chosenSlot = 1
            }

            guard (1...4).contains(chosenSlot) else {
                reply("AMS slots are one through four.")
                clearPendingPrint()
                return
            }

            let mapping = [FilamentMapping(
                id: UUID().uuidString,
                printFilamentID: "0",
                amsSlot: chosenSlot,
                confidence: pending.requestedColor == nil ? 0.7 : 0.95
            )]

            reply("Sending \(pending.candidate.name) to the P1S using AMS slot \(chosenSlot)…", speak: false)
            let p = try requirePrinter()
            try await p.uploadAndStart(fileURL: fileURL, displayName: pending.candidate.name, mappings: mapping)
            reply("Print command sent to the P1S.")
            clearPendingPrint()
        } catch {
            reply("I couldn't complete that print: \(error.localizedDescription)")
        }
    }

    func cancelPendingPrint() {
        guard pendingPrint != nil else { return }
        clearPendingPrint()
        reply("Cancelled. Nothing was sent to the P1S.")
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
            reply("P1S connection details are incomplete. Open Settings and check them.")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let probe = P1SStatusProbe(host: host, serial: serial, accessCode: code)
            let newStatus = try await probe.fetchStatus()
            status = newStatus
            await refreshAMSState()
            if showSuccessMessage {
                let job = newStatus.jobName.map { " Current job: \($0)." } ?? ""
                reply("P1S is \(newStatus.state.rawValue). \(Int(newStatus.progress)) percent complete.\(job)")
            }
        } catch {
            status = PrinterStatus(state: .offline, errorMessage: error.localizedDescription)
            reply("I can't reach the P1S right now: \(error.localizedDescription)")
        }
    }

    private func refreshAMSState() async {
        guard let printer else { return }
        do {
            ams = try await printer.amsState()
        } catch {
            // AMS data is helpful for color selection but should not make printer status fail.
        }
    }

    private func searchForPrint(query: String, color: String?, slot: Int?) async {
        guard !isBusy else { return }
        guard makerWorldSignedIn else {
            reply("Connect your MakerWorld account once in Settings before I can download print profiles.")
            showSetup = true
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            reply("Searching MakerWorld for a P1S-ready \(query)…", speak: false)
            let results = try await modelProvider.searchPrintProfiles(
                query: query,
                printer: "Bambu Lab P1S",
                nozzle: "0.4 mm",
                material: "PLA"
            )
            guard let best = results.first else {
                reply("I couldn't find a usable P1S MakerWorld result for \(query).")
                return
            }

            pendingPrint = PendingPrint(candidate: best, requestedColor: color, requestedSlot: slot)
            pendingPrintName = best.name
            let slotText = slot.map { " using AMS slot \($0)" } ?? ""
            let colorText = color.map { " in \($0)" } ?? ""
            reply("I found \(best.name)\(colorText)\(slotText). It's ready for your authorization. Do you want me to print it?")
        } catch {
            reply("Online model search failed: \(error.localizedDescription)")
        }
    }

    private func bestCachedSlot(for color: String?) -> Int? {
        guard let requested = color?.lowercased() else { return nil }
        return ams.filaments.first(where: { $0.colorName.lowercased() == requested })?.slot
    }

    private func printerAction(_ name: String, _ action: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await action()
            reply("P1S \(name) command sent.")
        } catch {
            reply("I couldn't send the \(name) command: \(error.localizedDescription)")
        }
    }

    private func reply(_ text: String, speak: Bool = true) {
        messages.append((text, false))
        if speak {
            speech.speak(text.replacingOccurrences(of: "\n", with: " "))
        }
    }
}

@MainActor
private final class JarvisBrain {
    #if canImport(FoundationModels)
    private var session: LanguageModelSession?
    #endif

    var availabilityLabel: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable ? "ON-DEVICE AI" : "AI UNAVAILABLE"
        }
        #endif
        return "CORE COMMANDS"
    }

    func respond(to prompt: String, memories: [String]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            if session == nil {
                session = LanguageModelSession(instructions: """
                You are Jarvis, a polished personal AI assistant running locally on the user's iPhone. Be calm, concise, capable, observant, and lightly witty. Prefer short spoken-friendly answers unless detail is requested. Never claim you performed an action unless the app actually did it. Printer actions are handled by dedicated app controls, so do not pretend to start, pause, cancel, or modify a print. If asked about something that requires live internet data, say that live web lookup is not connected yet instead of inventing current information.
                """)
            }

            let memoryContext = memories.isEmpty
                ? "No saved user memories."
                : "Saved user memories:\n" + memories.suffix(20).map { "- \($0)" }.joined(separator: "\n")

            let response = try await session!.respond(to: """
                \(memoryContext)

                User: \(prompt)
                Respond naturally as Jarvis.
                """)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif

        return fallbackResponse(for: prompt)
    }

    private func fallbackResponse(for prompt: String) -> String {
        let lower = prompt.lowercased()
        if lower.contains("what time") {
            return "It's \(Date.now.formatted(date: .omitted, time: .shortened))."
        }
        if lower.contains("what day") || lower.contains("date") {
            return "Today is \(Date.now.formatted(date: .complete, time: .omitted))."
        }
        if lower.contains("who are you") || lower.contains("what are you") {
            return "I'm Jarvis. Voice link, local memory, and printer control are online. My full on-device AI brain will activate when Apple Intelligence is available to this build."
        }
        if lower.contains("hello") || lower == "hi" || lower == "hey" {
            return "Hello. What can I do for you?"
        }
        return "I heard you. My core commands are online, but the full on-device language model isn't available to this build yet."
    }
}
