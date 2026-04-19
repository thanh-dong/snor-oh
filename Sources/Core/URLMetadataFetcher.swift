import Foundation

/// Best-effort OpenGraph + title + favicon extractor for bucketed URLs.
///
/// Runs a single HTTP GET with a 3 s timeout, reads at most 64 KB of the body,
/// and pulls:
///   - `<title>…</title>`
///   - `<meta property="og:image" content="…">`
///   - `<link rel="icon" href="…">`
///
/// Returns `nil` on any failure (no network, 4xx, 5xx, bad HTML, timeout). This
/// is a polish feature — the URL item is fully usable without it.
enum URLMetadataFetcher {

    private static let maxBodyBytes = 64 * 1024
    private static let timeoutSecs: TimeInterval = 3

    static func fetch(_ urlString: String) async -> BucketItem.URLMetadata? {
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSecs
        request.setValue(
            "Mozilla/5.0 snor-oh Bucket; +https://github.com/thanh-dong/snor-oh",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let prefix = data.prefix(maxBodyBytes)
            let html = String(data: prefix, encoding: .utf8)
                ?? String(data: prefix, encoding: .isoLatin1)
                ?? ""

            let title = extractTitle(from: html)
            let ogImage = extractOGImage(from: html, base: url)
            let favicon = extractFavicon(from: html, base: url)

            return .init(
                urlString: urlString,
                title: title,
                faviconPath: favicon?.absoluteString,  // stored as absolute URL; caller may
                ogImagePath: ogImage?.absoluteString   // download + cache separately.
            )
        } catch {
            return nil
        }
    }

    // MARK: - Regex extractors (deliberately tiny — no HTML parser dep)

    private static func extractTitle(from html: String) -> String? {
        guard let range = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>",
                                     options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let slice = String(html[range])
        // Strip tags + whitespace
        let inner = slice
            .replacingOccurrences(of: "<title[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</title>", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = decodeHTMLEntities(inner)
        return decoded.isEmpty ? nil : decoded
    }

    private static func extractOGImage(from html: String, base: URL) -> URL? {
        return extractMeta(property: "og:image", from: html)
            .flatMap { URL(string: $0, relativeTo: base) }
    }

    private static func extractFavicon(from html: String, base: URL) -> URL? {
        // <link rel="icon" href="…"> or rel="shortcut icon"
        let pattern = "<link[^>]+rel=[\"']([^\"']*icon[^\"']*)[\"'][^>]*href=[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return base.scheme.flatMap { URL(string: "\($0)://\(base.host ?? "")/favicon.ico") }
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        if let match = regex.firstMatch(in: html, options: [], range: range),
           match.numberOfRanges >= 3,
           let hrefRange = Range(match.range(at: 2), in: html) {
            return URL(string: String(html[hrefRange]), relativeTo: base)
        }
        // Fallback to /favicon.ico
        if let scheme = base.scheme, let host = base.host {
            return URL(string: "\(scheme)://\(host)/favicon.ico")
        }
        return nil
    }

    private static func extractMeta(property: String, from html: String) -> String? {
        let pattern = "<meta[^>]+property=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*content=[\"']([^\"']+)[\"']"
        if let match = firstCapture(pattern: pattern, in: html) {
            return decodeHTMLEntities(match)
        }
        // Try reversed attribute order
        let reverse = "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*property=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"']"
        return firstCapture(pattern: reverse, in: html).map(decodeHTMLEntities)
    }

    private static func firstCapture(pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[captured])
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
