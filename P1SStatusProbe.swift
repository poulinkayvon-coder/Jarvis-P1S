import Foundation
import Network
import Security

/// Small, crash-safe MQTT probe used by the UI status button.
/// It deliberately keeps its networking isolated from the print transport so a
/// failed status request can be reported to the user instead of terminating the app.
actor P1SStatusProbe {
    private let host: String
    private let serial: String
    private let accessCode: String

    init(host: String, serial: String, accessCode: String) {
        self.host = host
        self.serial = serial
        self.accessCode = accessCode
    }

    func fetchStatus() async throws -> PrinterStatus {
        let client = SafeMQTTClient(host: host, username: "bblp", password: accessCode)
        defer { Task { await client.close() } }
        try await client.connect()
        try await client.subscribe(topic: "device/\(serial)/report")
        try await client.publish(topic: "device/\(serial)/request", payload: Data(#"{"pushing":{"command":"pushall"}}"#.utf8))

        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            guard let data = try await client.nextPublish(timeout: 1.5) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let print = json["print"] as? [String: Any] else { continue }
            return PrinterStatus(
                state: Self.state(from: print["gcode_state"] as? String),
                progress: (print["mc_percent"] as? NSNumber)?.doubleValue ?? 0,
                remainingSeconds: (print["mc_remaining_time"] as? NSNumber)?.intValue,
                bedTemperature: (print["bed_temper"] as? NSNumber)?.doubleValue,
                nozzleTemperature: (print["nozzle_temper"] as? NSNumber)?.doubleValue,
                jobName: print["subtask_name"] as? String,
                errorMessage: nil
            )
        }
        throw JarvisError.timeout
    }

    private static func state(from value: String?) -> PrinterState {
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

private actor SafeMQTTClient {
    private let host: String
    private let username: String
    private let password: String
    private var connection: NWConnection?
    private var buffer = Data()
    private var packetID: UInt16 = 1

    init(host: String, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }

    func connect() async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, DispatchQueue.global(qos: .utility))
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let c = NWConnection(host: NWEndpoint.Host(host), port: 8883, using: params)
        connection = c
        try await waitUntilReady(c)

        var body = Data()
        body.appendMQTTStringSafe("MQTT")
        body.append(4)
        body.append(0xC2)
        body.append(contentsOf: [0, 60])
        body.appendMQTTStringSafe("jarvis-status-\(UUID().uuidString)")
        body.appendMQTTStringSafe(username)
        body.appendMQTTStringSafe(password)
        try await send(Data([0x10]) + Self.remainingLength(body.count) + body)

        guard let connack = try await receivePacket(timeout: 5), connack.count >= 4, connack[0] >> 4 == 2 else {
            throw JarvisError.timeout
        }
        guard connack[3] == 0 else { throw ProbeError.authenticationFailed(Int(connack[3])) }
    }

    func subscribe(topic: String) async throws {
        let id = packetID
        packetID &+= 1
        var body = Data([UInt8(id >> 8), UInt8(id & 0xff)])
        body.appendMQTTStringSafe(topic)
        body.append(0)
        try await send(Data([0x82]) + Self.remainingLength(body.count) + body)
        guard let ack = try await receivePacket(timeout: 5), ack.first.map({ $0 >> 4 }) == 9 else {
            throw JarvisError.timeout
        }
    }

    func publish(topic: String, payload: Data) async throws {
        var body = Data()
        body.appendMQTTStringSafe(topic)
        body.append(payload)
        try await send(Data([0x30]) + Self.remainingLength(body.count) + body)
    }

    func nextPublish(timeout: TimeInterval) async throws -> Data? {
        guard let packet = try await receivePacket(timeout: timeout), packet.count >= 2 else { return nil }
        guard packet[0] >> 4 == 3 else { return nil }
        var index = 1
        let (remaining, used) = Self.decodeRemaining(packet, from: index)
        index += used
        guard remaining >= 2, index + 2 <= packet.count else { return nil }
        let topicLength = Int(packet[index]) << 8 | Int(packet[index + 1])
        index += 2 + topicLength
        if (packet[0] & 0x06) != 0 { index += 2 }
        guard index <= packet.count else { return nil }
        return Data(packet[index...])
    }

    func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func waitUntilReady(_ c: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>(continuation)
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed(())
                case .failed(let error): gate.fail(error)
                case .cancelled: gate.fail(JarvisError.connectionClosed)
                default: break
                }
            }
            c.start(queue: DispatchQueue(label: "jarvis.safe-mqtt"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 7) { gate.fail(JarvisError.timeout) }
        }
    }

    private func send(_ data: Data) async throws {
        guard let c = connection else { throw JarvisError.connectionClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func receivePacket(timeout: TimeInterval) async throws -> Data? {
        if let packet = extractPacket() { return packet }
        guard let c = connection else { throw JarvisError.connectionClosed }

        let incoming: Data? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            let gate = ContinuationGate<Data?>(continuation)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error { gate.fail(error) }
                else if complete && (data == nil || data!.isEmpty) { gate.fail(JarvisError.connectionClosed) }
                else { gate.succeed(data) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.succeed(nil) }
        }

        if let incoming, !incoming.isEmpty { buffer.append(incoming) }
        return extractPacket()
    }

    private func extractPacket() -> Data? {
        guard buffer.count >= 2 else { return nil }
        let (length, used) = Self.decodeRemaining(buffer, from: 1)
        let total = 1 + used + length
        guard buffer.count >= total else { return nil }
        let packet = Data(buffer.prefix(total))
        buffer.removeFirst(total)
        return packet
    }

    private static func remainingLength(_ value: Int) -> Data {
        var x = value
        var data = Data()
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 128 }
            data.append(byte)
        } while x > 0
        return data
    }

    private static func decodeRemaining(_ data: Data, from start: Int) -> (Int, Int) {
        var multiplier = 1
        var value = 0
        var used = 0
        var i = start
        while i < data.count {
            let byte = Int(data[i])
            used += 1
            value += (byte & 127) * multiplier
            if byte & 128 == 0 { break }
            multiplier *= 128
            i += 1
        }
        return (value, used)
    }
}

private final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private enum ProbeError: LocalizedError {
    case authenticationFailed(Int)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let code):
            return "The P1S rejected the LAN login (MQTT code \(code)). Re-check the LAN access code and printer IP."
        }
    }
}

private extension Data {
    mutating func appendMQTTStringSafe(_ string: String) {
        let data = Data(string.utf8)
        append(UInt8(data.count >> 8))
        append(UInt8(data.count & 0xff))
        append(data)
    }
}
