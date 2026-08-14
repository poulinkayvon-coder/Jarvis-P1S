import Foundation

struct MakerWorldProvider: ModelProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchPrintProfiles(query: String, printer: String, nozzle: String, material: String) async throws -> [ModelCandidate] {
        var components = URLComponents(string: "https://makerworld.com/en/search/models")!
        components.queryItems = [URLQueryItem(name: "keyword", value: query)]
        guard let url = components.url else { throw JarvisError.onlineSearchFailed }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw JarvisError.onlineSearchFailed
        }

        let links = Self.extractModelLinks(from: html)
        var seen = Set<String>()
        var results: [ModelCandidate] = []

        for link in links where results.count < 8 {
            guard seen.insert(link.absoluteString).inserted else { continue }
            let name = Self.titleNearModelURL(link.absoluteString, in: html) ?? query.capitalized
            results.append(ModelCandidate(
                id: link.absoluteString,
                name: name,
                downloadURL: link,
                source: "MakerWorld",
                notes: "Online MakerWorld result. Jarvis will verify a downloadable 3MF before printing.",
                printer: printer
            ))
        }
        return results
    }

    func download(profile: ModelCandidate) async throws -> URL {
        var request = URLRequest(url: profile.downloadURL)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw JarvisError.profilePageFailed
        }

        guard let direct = Self.extract3MFURL(from: html, baseURL: profile.downloadURL) else {
            throw JarvisError.noDownloadableProfile
        }

        var downloadRequest = URLRequest(url: direct)
        downloadRequest.setValue(request.value(forHTTPHeaderField: "User-Agent"), forHTTPHeaderField: "User-Agent")
        downloadRequest.timeoutInterval = 30
        let (fileData, fileResponse) = try await session.data(for: downloadRequest)
        guard let fileHTTP = fileResponse as? HTTPURLResponse, (200..<300).contains(fileHTTP.statusCode), !fileData.isEmpty else {
            throw JarvisError.profileDownloadFailed
        }

        let suggested = Self.safeFilename(profile.name) + ".3mf"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(suggested)
        try? FileManager.default.removeItem(at: destination)
        try fileData.write(to: destination, options: .atomic)
        return destination
    }

    private static func extractModelLinks(from html: String) -> [URL] {
        let patterns = [
            #"https://makerworld\.com/(?:en/)?models/[0-9]+[^\"'<> ]*"#,
            #"/(?:en/)?models/[0-9]+[^\"'<> ]*"#
        ]
        var urls: [URL] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in regex.matches(in: html, range: range) {
                guard let r = Range(match.range, in: html) else { continue }
                var raw = String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
                if raw.hasPrefix("/") { raw = "https://makerworld.com" + raw }
                if let u = URL(string: raw) { urls.append(u) }
            }
        }
        return urls
    }

    private static func extract3MFURL(from html: String, baseURL: URL) -> URL? {
        let cleaned = html
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")

        let patterns = [
            #"https?://[^\"'<> ]+\.3mf(?:\?[^\"'<> ]*)?"#,
            #"\"(?:downloadUrl|download_url|fileUrl|file_url)\"\s*:\s*\"([^\"]+\.3mf[^\"]*)\""#,
            #"href=\"([^\"]+\.3mf[^\"]*)\""#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            guard let match = regex.firstMatch(in: cleaned, range: range) else { continue }
            let captureIndex = match.numberOfRanges > 1 ? 1 : 0
            guard let r = Range(match.range(at: captureIndex), in: cleaned) else { continue }
            let raw = String(cleaned[r])
                .replacingOccurrences(of: "\\u0026", with: "&")
                .replacingOccurrences(of: "\\u003D", with: "=")
            if let absolute = URL(string: raw), absolute.scheme != nil { return absolute }
            if let relative = URL(string: raw, relativeTo: baseURL)?.absoluteURL { return relative }
        }
        return nil
    }

    private static func titleNearModelURL(_ modelURL: String, in html: String) -> String? {
        guard let range = html.range(of: modelURL) else { return nil }
        let start = html.index(range.lowerBound, offsetBy: -min(500, html.distance(from: html.startIndex, to: range.lowerBound)))
        let end = html.index(range.upperBound, offsetBy: min(500, html.distance(from: range.upperBound, to: html.endIndex)))
        let snippet = String(html[start..<end])
        let titlePatterns = [#"\"name\"\s*:\s*\"([^\"]{2,100})\""#, #"\"title\"\s*:\s*\"([^\"]{2,100})\""#]
        for pattern in titlePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = NSRange(snippet.startIndex..<snippet.endIndex, in: snippet)
            if let match = regex.firstMatch(in: snippet, range: ns), let r = Range(match.range(at: 1), in: snippet) {
                return String(snippet[r]).replacingOccurrences(of: "\\u0026", with: "&")
            }
        }
        return nil
    }

    private static func safeFilename(_ value: String) -> String {
        let sanitized = value.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return sanitized.isEmpty ? "jarvis_download" : String(sanitized.prefix(80))
    }
}
