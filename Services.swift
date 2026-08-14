import Foundation
import Security

protocol ModelProvider {
    func searchPrintProfiles(
        query: String,
        printer: String,
        nozzle: String,
        material: String
    ) async throws -> [ModelCandidate]

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

struct UnconfiguredModelProvider: ModelProvider {
    func searchPrintProfiles(query: String, printer: String, nozzle: String, material: String) async throws -> [ModelCandidate] {
        throw JarvisError.notConfigured("3MF provider")
    }

    func download(profile: ModelCandidate) async throws -> URL {
        throw JarvisError.notConfigured("3MF provider")
    }
}

actor BambuP1STransport: PrinterTransport {
    private let host: String
    private let accessCode: String

    init(host: String, accessCode: String) {
        self.host = host
        self.accessCode = accessCode
    }

    func connect() async throws {
        // TODO: implement the tested P1S LAN MQTT/FTPS transport.
    }

    func status() async throws -> PrinterStatus {
        throw JarvisError.notConfigured("P1S transport")
    }

    func amsState() async throws -> AMSState {
        throw JarvisError.notConfigured("P1S AMS transport")
    }

    func uploadAndStart(fileURL: URL, displayName: String, mappings: [FilamentMapping]) async throws {
        throw JarvisError.notConfigured("P1S print transport")
    }

    func pause() async throws { throw JarvisError.notConfigured("P1S transport") }
    func resume() async throws { throw JarvisError.notConfigured("P1S transport") }
    func cancel() async throws { throw JarvisError.notConfigured("P1S transport") }
}

enum JarvisError: LocalizedError {
    case notConfigured(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured(let item): return "\(item) is not configured yet."
        }
    }
}

enum Keychain {
    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
