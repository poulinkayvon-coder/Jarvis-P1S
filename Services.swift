import Foundation
import Security
import Network

protocol ModelProvider {
    func searchPrintProfiles(query: String, printer: String, nozzle: String, material: String) async throws -> [ModelCandidate]
    func download(profile: ModelCandidate) async throws -> URL
}

protocol PrinterTransport {
    func connect() async throws
    func status() async throws -> PrinterStatus
    func amsState() async throws -> AMSState
    func uploadAndStart(fileURL: URL, displayName: String, mappings: [FilamentMapping]) async throws
    func pause() async throws
    func resume() async throws
    func cancel() async throws
}

struct Local3MFProvider: ModelProvider {
    private let fm = FileManager.default

    private var documents: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func searchPrintProfiles(query: String, printer: String, nozzle: String, material: String) async throws -> [ModelCandidate] {
        let files = try fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "3mf" || $0.lastPathComponent.lowercased().hasSuffix(".gcode.3mf") }
            .filter { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }

        return files.map {
            ModelCandidate(
                id: $0.path,
                name: $0.deletingPathExtension().lastPathComponent,
                downloadURL: $0,
                source: "On My iPhone",
                notes: "Pre-sliced 3MF. Jarvis uses Metadata/plate_1.gcode.",
                printer: printer
            )
        }
    }

    func download(profile: ModelCandidate) async throws -> URL {
        guard fm.fileExists(atPath: profile.downloadURL.path) else {
            throw JarvisError.fileNotFound
        }
        return profile.downloadURL
    }

    static func importFile(from url: URL) throws -> URL {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard ext == "3mf" || url.lastPathComponent.lowercased().hasSuffix(".gcode.3mf") else {
            throw JarvisError.invalidFileType
        }

        var name = url.lastPathComponent
        if !name.lowercased().hasSuffix(".3mf") { name += ".3mf" }
        var destination = documents.appendingPathComponent(name)
        if fm.fileExists(atPath: destination.path) {
            destination = documents.appendingPathComponent("\(UUID().uuidString)-\(name)")
        }
        try fm.copyItem(at: url, to: destination)
        return destination
    }
}

actor BambuP1STransport: PrinterTransport {
    private let host: String
    private let serial: String
    private let accessCode: String

    init(host: String, serial: String, accessCode: String) {
        self.host = host
        self.serial = serial
        self.accessCode = accessCode
    }

    func connect() async throws {
        let mqtt = try await MQTTConnection(host: host, username: "bblp", password: accessCode, clientID: "jarvis-\(UUID().uuidString)")
        try await mqtt.connect()
        await mqtt.close()
    }

    func status() async throws -> PrinterStatus {
        let mqtt = try await MQTTConnection(host: host, username: "bblp", password: accessCode, clientID: "jarvis-status-\(UUID().uuidString)")
        try await mqtt.connect()
        try await mqtt.subscribe(topic: "device/\(serial)/report")
        try await mqtt.publish(topic: "device/\(serial)/request", payload: Data(#"{"pushing":{"command":"pushall"}}"#.utf8))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let data = try await mqtt.nextPublish(timeout: 1),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let print = json["print"] as? [String: Any] {
                let result = PrinterStatus(
                    state: PrinterState.fromBambu(print["gcode_state"] as? String),
                    progress: (print["mc_percent"] as? NSNumber)?.doubleValue ?? 0,
                    remainingSeconds: (print["mc_remaining_time"] as? NSNumber)?.intValue,
                    bedTemperature: (print["bed_temper"] as? NSNumber)?.doubleValue,
                    nozzleTemperature: (print["nozzle_temper"] as? NSNumber)?.doubleValue,
                    jobName: print["subtask_name"] as? String,
                    errorMessage: nil
                )
                await mqtt.close()
                return result
            }
        }
        await mqtt.close()
        throw JarvisError.timeout
    }

    func amsState() async throws -> AMSState {
        let mqtt = try await MQTTConnection(host: host, username: "bblp", password: accessCode, clientID: "jarvis-ams-\(UUID().uuidString)")
        try await mqtt.connect()
        try await mqtt.subscribe(topic: "device/\(serial)/report")
        try await mqtt.publish(topic: "device/\(serial)/request", payload: Data(#"{"pushing":{"command":"pushall"}}"#.utf8))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let data = try await mqtt.nextPublish(timeout: 1),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ams = json["ams"] as? [String: Any],
               let units = ams["ams"] as? [[String: Any]] {
                var filaments: [AMSFilament] = []
                for (unitIndex, unit) in units.enumerated() {
                    let trays = unit["tray"] as? [[String: Any]] ?? []
                    for (trayIndex, tray) in trays.enumerated() {
                        let color = tray["tray_color"] as? String
                        let type = tray["tray_type"] as? String ?? "Unknown"
                        filaments.append(AMSFilament(id: "\(unitIndex)-\(trayIndex)", slot: unitIndex * 4 + trayIndex + 1, material: type, colorName: Self.colorName(color), hexColor: color, isLoaded: true))
                    }
                }
                await mqtt.close()
                return AMSState(filaments: filaments)
            }
        }
        await mqtt.close()
        throw JarvisError.timeout
    }

    func uploadAndStart(fileURL: URL, displayName: String, mappings: [FilamentMapping]) async throws {
        guard fileURL.pathExtension.lowercased() == "3mf" || fileURL.lastPathComponent.lowercased().hasSuffix(".gcode.3mf") else {
            throw JarvisError.invalidFileType
        }

        let remote = Self.safeRemoteName(displayName)
        let ftp = try await FTPSClient(host: host, username: "bblp", password: accessCode)
        do {
            try await ftp.connect()
            try await ftp.upload(fileURL: fileURL, remoteName: remote)
            await ftp.close()
        } catch {
            await ftp.close()
            throw error
        }

        let mqtt = try await MQTTConnection(host: host, username: "bblp", password: accessCode, clientID: "jarvis-print-\(UUID().uuidString)")
        try await mqtt.connect()

        var mapping = Array(repeating: -1, count: 5)
        for m in mappings where m.amsSlot >= 1 && m.amsSlot <= 4 {
            let index = max(0, min(4, mapping.firstIndex(of: -1) ?? 4))
            mapping[index] = m.amsSlot - 1
        }
        if mappings.isEmpty { mapping = [0, -1, -1, -1, -1] }

        let payload: [String: Any] = [
            "print": [
                "sequence_id": "0",
                "command": "project_file",
                "param": "Metadata/plate_1.gcode",
                "project_id": "0",
                "profile_id": "0",
                "task_id": "0",
                "subtask_id": "0",
                "subtask_name": remote,
                "file": remote,
                "url": "ftp:///\(remote)",
                "md5": "",
                "timelapse": false,
                "bed_type": "auto",
                "bed_leveling": true,
                "bed_levelling": true,
                "flow_cali": true,
                "vibration_cali": true,
                "layer_inspect": true,
                "use_ams": true,
                "ams_mapping": mapping
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await mqtt.publish(topic: "device/\(serial)/request", payload: data)
        await mqtt.close()
    }

    func pause() async throws { try await simplePrintCommand("pause") }
    func resume() async throws { try await simplePrintCommand("resume") }
    func cancel() async throws { try await simplePrintCommand("stop") }

    private func simplePrintCommand(_ command: String) async throws {
        let mqtt = try await MQTTConnection(host: host, username: "bblp", password: accessCode, clientID: "jarvis-cmd-\(UUID().uuidString)")
        try await mqtt.connect()
        let payload = ["print": ["sequence_id": "0", "command": command, "param": ""]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await mqtt.publish(topic: "device/\(serial)/request", payload: data)
        await mqtt.close()
    }

    private static func safeRemoteName(_ name: String) -> String {
        let base = name.replacingOccurrences(of: ".3mf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ".gcode", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return "jarvis_\(base.isEmpty ? "print" : base)_\(Int(Date().timeIntervalSince1970)).gcode.3mf"
    }

    private static func colorName(_ hex: String?) -> String {
        guard let hex else { return "Unknown" }
        let h = hex.prefix(6).lowercased()
        switch h {
        case "ff0000": return "Red"
        case "00ff00": return "Green"
        case "0000ff": return "Blue"
        case "ffff00": return "Yellow"
        case "ffffff": return "White"
        case "000000": return "Black"
        default: return "Custom"
        }
    }
}

private extension PrinterState {
    static func fromBambu(_ value: String?) -> PrinterState {
        switch value?.lowercased() {
        case "idle": return .idle
        case "prepare", "prepare printing", "slicing": return .preparing
        case "running", "printing": return .printing
        case "pause", "paused": return .paused
        case "finish", "finished": return .finished
        case "failed", "error": return .error
        default: return .offline
        }
    }
}

private actor MQTTConnection {
    private let host: String
    private let username: String
    private let password: String
    private let clientID: String
    private var connection: NWConnection?
    private var buffer = Data()
    private var packetID: UInt16 = 1

    init(host: String, username: String, password: String, clientID: String) {
        self.host = host; self.username = username; self.password = password; self.clientID = clientID
    }

    func connect() async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, DispatchQueue.global(qos: .utility))
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let c = NWConnection(host: NWEndpoint.Host(host), port: 8883, using: params)
        connection = c
        try await waitUntilReady(c, timeout: 7)

        var body = Data()
        body.appendMQTTString("MQTT")
        body.append(4)
        body.append(0xC2)
        body.append(contentsOf: [0, 60])
        body.appendMQTTString(clientID)
        body.appendMQTTString(username)
        body.appendMQTTString(password)
        try await send(packet: Data([0x10]) + MQTTConnection.remainingLength(body.count) + body)

        guard let connack = try await receivePacket(timeout: 5), connack.count >= 4, connack[0] >> 4 == 2 else {
            throw JarvisError.timeout
        }
        guard connack[3] == 0 else { throw JarvisError.authenticationFailed(Int(connack[3])) }
    }

    func subscribe(topic: String) async throws {
        let id = packetID; packetID &+= 1
        var body = Data([UInt8(id >> 8), UInt8(id & 0xff)])
        body.appendMQTTString(topic); body.append(0)
        try await send(packet: Data([0x82]) + MQTTConnection.remainingLength(body.count) + body)
        guard let ack = try await receivePacket(timeout: 5), ack.count >= 5, ack[0] >> 4 == 9 else {
            throw JarvisError.timeout
        }
        guard ack.last != 0x80 else { throw JarvisError.subscriptionRejected }
    }

    func publish(topic: String, payload: Data) async throws {
        var body = Data(); body.appendMQTTString(topic); body.append(payload)
        try await send(packet: Data([0x30]) + MQTTConnection.remainingLength(body.count) + body)
    }

    func nextPublish(timeout: TimeInterval) async throws -> Data? {
        guard let packet = try await receivePacket(timeout: timeout) else { return nil }
        guard packet.count >= 2 else { return nil }
        let type = packet[0] >> 4
        guard type == 3 else { return nil }
        var index = 1
        let (remaining, used) = MQTTConnection.decodeRemaining(packet, from: index)
        index += used
        guard remaining >= 2, index + 2 <= packet.count else { return nil }
        let topicLength = Int(packet[index]) << 8 | Int(packet[index + 1]); index += 2
        guard index + topicLength <= packet.count else { return nil }
        index += topicLength
        if (packet[0] & 0x06) != 0 {
            guard index + 2 <= packet.count else { return nil }
            index += 2
        }
        guard index <= packet.count else { return nil }
        return Data(packet[index...])
    }

    func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
    }

    private func waitUntilReady(_ c: NWConnection, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = TransportContinuationGate<Void>(continuation)
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed(())
                case .failed(let error): gate.fail(error)
                case .cancelled: gate.fail(JarvisError.connectionClosed)
                default: break
                }
            }
            c.start(queue: DispatchQueue(label: "jarvis.mqtt"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.fail(JarvisError.timeout) }
        }
    }

    private func send(packet: Data) async throws {
        guard let c = connection else { throw JarvisError.connectionClosed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: packet, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func receivePacket(timeout: TimeInterval) async throws -> Data? {
        if let complete = extractPacket() { return complete }
        guard let c = connection else { throw JarvisError.connectionClosed }

        let incoming: Data? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            let gate = TransportContinuationGate<Data?>(continuation)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error { gate.fail(error) }
                else if isComplete && (data == nil || data!.isEmpty) { gate.fail(JarvisError.connectionClosed) }
                else { gate.succeed(data) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.succeed(nil) }
        }

        if let incoming, !incoming.isEmpty { buffer.append(incoming) }
        return extractPacket()
    }

    private func extractPacket() -> Data? {
        guard buffer.count >= 2 else { return nil }
        let (length, used) = MQTTConnection.decodeRemaining(buffer, from: 1)
        guard used > 0 else { return nil }
        let total = 1 + used + length
        guard buffer.count >= total else { return nil }
        let packet = Data(buffer.prefix(total)); buffer.removeFirst(total); return packet
    }

    private static func remainingLength(_ value: Int) -> Data {
        var x = value; var d = Data()
        repeat { var byte = UInt8(x % 128); x /= 128; if x > 0 { byte |= 128 }; d.append(byte) } while x > 0
        return d
    }

    private static func decodeRemaining(_ data: Data, from start: Int) -> (Int, Int) {
        var multiplier = 1, value = 0, used = 0
        var i = start
        while i < data.count && used < 4 {
            let byte = Int(data[i]); used += 1; value += (byte & 127) * multiplier
            if byte & 128 == 0 { return (value, used) }
            multiplier *= 128; i += 1
        }
        return (0, 0)
    }
}

private final class FTPSClient {
    private let host: String
    private let username: String
    private let password: String
    private var control: NWConnection?
    private var controlBuffer = Data()

    init(host: String, username: String, password: String) async throws {
        self.host = host; self.username = username; self.password = password
    }

    func connect() async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, DispatchQueue.global(qos: .utility))
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let c = NWConnection(host: NWEndpoint.Host(host), port: 990, using: params)
        control = c
        try await waitUntilReady(c, timeout: 7)
        _ = try await readResponse(timeout: 7)
        _ = try await command("USER \(username)")
        _ = try await command("PASS \(password)")
        _ = try await command("TYPE I")
    }

    func upload(fileURL: URL, remoteName: String) async throws {
        let response = try await command("PASV")
        guard let port = Self.parsePassivePort(response) else { throw JarvisError.ftpProtocol(response) }
        let dataConnection = try await makeDataConnection(port: port)
        _ = try await command("STOR \(remoteName)")

        guard let stream = InputStream(url: fileURL) else { throw JarvisError.fileReadFailed }
        stream.open(); defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw stream.streamError ?? JarvisError.fileReadFailed }
            if count == 0 { break }
            try await send(data: Data(bytes[0..<count]), on: dataConnection)
        }
        dataConnection.cancel()
        let completion = try await readResponse(timeout: 15)
        guard completion.hasPrefix("2") else { throw JarvisError.ftpProtocol(completion) }
    }

    func close() async {
        if let c = control {
            c.send(content: Data("QUIT\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
        }
        control = nil
    }

    private func waitUntilReady(_ c: NWConnection, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = TransportContinuationGate<Void>(continuation)
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed(())
                case .failed(let error): gate.fail(error)
                case .cancelled: gate.fail(JarvisError.connectionClosed)
                default: break
                }
            }
            c.start(queue: DispatchQueue(label: "jarvis.ftps"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.fail(JarvisError.timeout) }
        }
    }

    private func makeDataConnection(port: UInt16) async throws -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, DispatchQueue.global(qos: .utility))
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw JarvisError.ftpProtocol("Invalid passive FTP port") }
        let c = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: params)
        try await waitUntilReady(c, timeout: 7)
        return c
    }

    private func send(data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    @discardableResult
    private func command(_ text: String) async throws -> String {
        guard let c = control else { throw JarvisError.connectionClosed }
        let data = Data("\(text)\r\n".utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
        let response = try await readResponse(timeout: 10)
        guard response.hasPrefix("2") || response.hasPrefix("3") else { throw JarvisError.ftpProtocol(response) }
        return response
    }

    private func readResponse(timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = extractLine() { return line }
            guard let c = control else { throw JarvisError.connectionClosed }

            let incoming: Data? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                let gate = TransportContinuationGate<Data?>(continuation)
                c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                    if let error { gate.fail(error) }
                    else if complete && (data == nil || data!.isEmpty) { gate.fail(JarvisError.connectionClosed) }
                    else { gate.succeed(data) }
                }
                let remaining = max(0.05, deadline.timeIntervalSinceNow)
                DispatchQueue.global().asyncAfter(deadline: .now() + remaining) { gate.succeed(nil) }
            }

            guard let incoming else { break }
            if !incoming.isEmpty { controlBuffer.append(incoming) }
        }
        throw JarvisError.timeout
    }

    private func extractLine() -> String? {
        guard let range = controlBuffer.range(of: Data([13, 10])) else { return nil }
        let line = String(data: controlBuffer[..<range.lowerBound], encoding: .utf8) ?? ""
        controlBuffer.removeSubrange(..<range.upperBound)
        return line
    }

    private static func parsePassivePort(_ response: String) -> UInt16? {
        guard let open = response.firstIndex(of: "("), let close = response.firstIndex(of: ")") else { return nil }
        let nums = response[response.index(after: open)..<close].split(separator: ",").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 6 else { return nil }
        let value = UInt32(nums[4]) * 256 + UInt32(nums[5])
        guard value > 0, value <= UInt32(UInt16.max) else { return nil }
        return UInt16(value)
    }
}

private final class TransportContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) { finish(.success(value)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

enum JarvisError: LocalizedError {
    case notConfigured(String)
    case timeout
    case connectionClosed
    case fileNotFound
    case fileReadFailed
    case invalidFileType
    case ftpProtocol(String)
    case authenticationFailed(Int)
    case subscriptionRejected

    var errorDescription: String? {
        switch self {
        case .notConfigured(let item): return "\(item) is not configured yet."
        case .timeout: return "The printer did not answer in time."
        case .connectionClosed: return "The printer connection closed."
        case .fileNotFound: return "The selected 3MF file could not be found."
        case .fileReadFailed: return "Jarvis could not read the 3MF file."
        case .invalidFileType: return "Please choose a pre-sliced .3mf or .gcode.3mf file."
        case .ftpProtocol(let response): return "P1S file transfer error: \(response)"
        case .authenticationFailed(let code): return "The P1S rejected the LAN login (MQTT code \(code)). Re-check the printer IP and LAN access code."
        case .subscriptionRejected: return "The P1S rejected the MQTT status subscription."
        }
    }
}

enum Keychain {
    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var item = base; item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension Data {
    mutating func appendMQTTString(_ string: String) {
        let data = Data(string.utf8)
        append(UInt8(data.count >> 8)); append(UInt8(data.count & 0xff)); append(data)
    }
}
