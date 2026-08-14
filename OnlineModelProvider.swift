import Foundation

struct MakerWorldLoginResult {
    let signedIn: Bool
    let needsVerificationCode: Bool
    let message: String
}

actor BambuCloudAuth {
    static let shared = BambuCloudAuth()

    private let loginURL = URL(string: "https://api.bambulab.com/v1/user-service/user/login")!

    func login(account: String, password: String, verificationCode: String) async throws -> MakerWorldLoginResult {
        let cleanAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanAccount.isEmpty else {
            throw MakerWorldError.authentication("Enter your Bambu/MakerWorld email first.")
        }
        guard !cleanPassword.isEmpty || !cleanCode.isEmpty else {
            throw MakerWorldError.authentication("Enter your password or verification code.")
        }

        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("JarvisP1S/1.0", forHTTPHeaderField: "User-Agent")

        let payload: [String: String]
        if !cleanCode.isEmpty {
            payload = ["account": cleanAccount, "code": cleanCode]
        } else {
            payload = ["account": cleanAccount, "password": cleanPassword]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MakerWorldError.network("Bambu login returned an invalid response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw MakerWorldError.authentication(Self.apiMessage(data) ?? "Bambu login failed (HTTP \(http.statusCode)).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MakerWorldError.network("Bambu login returned unreadable data.")
        }

        let token = (json["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let loginType = (json["loginType"] as? String) ?? ""

        if !token.isEmpty {
            Keychain.set(token, for: "bambu.cloudToken")
            UserDefaults.standard.set(cleanAccount, forKey: "bambu.account")
            return MakerWorldLoginResult(signedIn: true, needsVerificationCode: false, message: "MakerWorld is connected.")
        }

        if loginType.lowercased().contains("verify") {
            return MakerWorldLoginResult(
                signedIn: false,
                needsVerificationCode: true,
                message: "Bambu sent a verification code. Enter it in Setup and tap Sign In again."
            )
        }

        throw MakerWorldError.authentication(Self.apiMessage(data) ?? "Bambu did not return an access token.")
    }

    private static func apiMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["message", "error", "detail"] {
            if let value = json[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

actor MakerWorldProvider: ModelProvider {
    private let apiBase = URL(string: "https://api.bambulab.com/v1")!

    func searchPrintProfiles(query: String, printer: String, nozzle: String, material: String) async throws -> [ModelCandidate] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        let token = try requireToken()
        let searchPaths = [
            "search-service/select/design2",
            "search-service/searchlist"
        ]

        var designHits: [[String: Any]] = []
        var lastError: Error?

        for path in searchPaths {
            do {
                var comps = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
                comps.queryItems = [
                    URLQueryItem(name: "keyword", value: clean),
                    URLQueryItem(name: "q", value: clean),
                    URLQueryItem(name: "limit", value: "12"),
                    URLQueryItem(name: "offset", value: "0")
                ]
                guard let url = comps.url else { continue }
                let json = try await getJSON(url: url, token: token)
                designHits = Self.collectDesignObjects(from: json)
                if !designHits.isEmpty { break }
            } catch {
                lastError = error
            }
        }

        if designHits.isEmpty {
            if let lastError { throw lastError }
            return []
        }

        var candidates: [ModelCandidate] = []
        var seenProfiles = Set<Int>()

        for hit in designHits.prefix(8) {
            guard let designID = Self.intValue(hit["designId"] ?? hit["id"]) else { continue }
            let fallbackTitle = Self.stringValue(hit["title"] ?? hit["name"]) ?? clean

            do {
                let instancesURL = apiBase.appendingPathComponent("design-service/design/\(designID)/instances")
                let instancesJSON = try await getJSON(url: instancesURL, token: token)
                let profiles = Self.collectProfileObjects(from: instancesJSON)

                for profile in profiles {
                    guard let profileID = Self.intValue(profile["profileId"] ?? profile["id"]), !seenProfiles.contains(profileID) else { continue }
                    let profileText = Self.flattenText(profile).lowercased()
                    let explicitlyOtherPrinter = profileText.contains("a1 mini") || profileText.contains("a1mini") || profileText.contains("x1e") || profileText.contains("h2d") || profileText.contains("h2s")
                    let looksP1S = profileText.contains("p1s") || profileText.contains("p1 series") || profileText.contains("p1p") || !explicitlyOtherPrinter
                    guard looksP1S else { continue }

                    seenProfiles.insert(profileID)
                    let profileTitle = Self.stringValue(profile["title"] ?? profile["name"]) ?? fallbackTitle
                    let displayName = profileTitle.lowercased().contains(fallbackTitle.lowercased()) ? profileTitle : "\(fallbackTitle) — \(profileTitle)"
                    let notes = Self.profileNotes(profile)
                    let makerURL = URL(string: "https://makerworld.com/en/models/\(designID)")!
                    candidates.append(ModelCandidate(
                        id: "makerworld:\(designID):\(profileID)",
                        name: displayName,
                        downloadURL: makerURL,
                        source: "MakerWorld",
                        notes: notes,
                        printer: printer
                    ))
                    if candidates.count >= 6 { return candidates }
                }
            } catch {
                continue
            }
        }

        return candidates
    }

    func download(profile: ModelCandidate) async throws -> URL {
        let token = try requireToken()
        let ids = try Self.parseCandidateID(profile.id)

        let designURL = apiBase.appendingPathComponent("design-service/design/\(ids.designID)")
        let designJSON = try await getJSON(url: designURL, token: token)
        guard let modelID = Self.findString(named: "modelId", in: designJSON), !modelID.isEmpty else {
            throw MakerWorldError.invalidResponse("MakerWorld did not return the model identifier needed to download this profile.")
        }

        var comps = URLComponents(url: apiBase.appendingPathComponent("iot-service/api/user/profile/\(ids.profileID)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "model_id", value: modelID)]
        guard let downloadInfoURL = comps.url else { throw MakerWorldError.invalidResponse("Could not build the MakerWorld download request.") }
        let downloadInfo = try await getJSON(url: downloadInfoURL, token: token)
        guard let signedURLString = Self.findString(named: "url", in: downloadInfo),
              let signedURL = URL(string: signedURLString),
              signedURL.scheme == "https" else {
            throw MakerWorldError.invalidResponse("MakerWorld did not provide a downloadable 3MF URL.")
        }

        let allowedHosts = ["makerworld.bblmw.com", "public-cdn.bblmw.com", "amazonaws.com"]
        let host = (signedURL.host ?? "").lowercased()
        guard allowedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
            throw MakerWorldError.invalidResponse("MakerWorld returned an unexpected download host.")
        }

        var request = URLRequest(url: signedURL)
        request.setValue("JarvisP1S/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MakerWorldError.network("The MakerWorld 3MF download failed.")
        }
        guard data.count > 100 else { throw MakerWorldError.invalidResponse("The downloaded MakerWorld file was empty.") }
        guard data.count < 250_000_000 else { throw MakerWorldError.invalidResponse("The MakerWorld file is too large for Jarvis to handle safely.") }

        let safeName = profile.name
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
            .prefix(80)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("makerworld_\(ids.profileID)_\(safeName).gcode.3mf")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func requireToken() throws -> String {
        guard let token = Keychain.get("bambu.cloudToken"), !token.isEmpty else {
            throw MakerWorldError.authentication("Connect your Bambu/MakerWorld account in Setup so Jarvis can download print profiles.")
        }
        return token
    }

    private func getJSON(url: URL, token: String) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("JarvisP1S/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://makerworld.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MakerWorldError.network("MakerWorld returned an invalid response.") }
        if http.statusCode == 401 {
            throw MakerWorldError.authentication("Your MakerWorld sign-in expired. Open Setup and sign in again.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw MakerWorldError.network("MakerWorld request failed (HTTP \(http.statusCode)).")
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MakerWorldError.invalidResponse("MakerWorld returned unreadable data.")
        }
    }

    private static func parseCandidateID(_ id: String) throws -> (designID: Int, profileID: Int) {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "makerworld", let designID = Int(parts[1]), let profileID = Int(parts[2]) else {
            throw MakerWorldError.invalidResponse("This search result is missing its MakerWorld profile information.")
        }
        return (designID, profileID)
    }

    private static func collectDesignObjects(from value: Any) -> [[String: Any]] {
        var output: [[String: Any]] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                let hasTitle = dict["title"] != nil || dict["name"] != nil
                let hasID = dict["designId"] != nil || dict["id"] != nil
                if hasTitle && hasID { output.append(dict) }
                for child in dict.values { walk(child) }
            } else if let array = node as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(value)
        return output
    }

    private static func collectProfileObjects(from value: Any) -> [[String: Any]] {
        var output: [[String: Any]] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                let hasProfileID = dict["profileId"] != nil || (dict["id"] != nil && (dict["title"] != nil || dict["name"] != nil))
                if hasProfileID { output.append(dict) }
                for child in dict.values { walk(child) }
            } else if let array = node as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(value)
        return output
    }

    private static func profileNotes(_ profile: [String: Any]) -> String? {
        var pieces: [String] = []
        if let title = stringValue(profile["title"] ?? profile["name"]) { pieces.append(title) }
        if let time = intValue(profile["printTime"] ?? profile["prediction"] ?? profile["print_time"]) {
            let hours = time / 3600
            let minutes = (time % 3600) / 60
            pieces.append(hours > 0 ? "~\(hours)h \(minutes)m" : "~\(minutes)m")
        }
        if let weight = doubleValue(profile["weight"] ?? profile["totalWeight"] ?? profile["filamentWeight"]) {
            pieces.append(String(format: "%.0fg filament", weight))
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " • ")
    }

    private static func flattenText(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let dict = value as? [String: Any] { return dict.values.map(flattenText).joined(separator: " ") }
        if let array = value as? [Any] { return array.map(flattenText).joined(separator: " ") }
        return ""
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func findString(named key: String, in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let s = dict[key] as? String, !s.isEmpty { return s }
            for child in dict.values {
                if let found = findString(named: key, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findString(named: key, in: child) { return found }
            }
        }
        return nil
    }
}

enum MakerWorldError: LocalizedError {
    case authentication(String)
    case network(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .authentication(let message), .network(let message), .invalidResponse(let message): return message
        }
    }
}
