import Foundation

// Shared with the CellarShare extension.

/// A merchant's order email, reduced on the phone to what reading it needs: the
/// text, a few headers, and the product pictures it linked to. Built from a pasted
/// or shared message, a saved .eml, an HTML page, or a PDF's text.
struct OrderEmail: Codable, Equatable {
    struct ImageRef: Codable, Equatable, Hashable {
        var url: String
        var alt: String = ""
    }

    var id = UUID()
    var text: String
    var subject = ""
    var from = ""
    /// The email's Date header, as sent (parsed later; formats vary).
    var date = ""
    var images: [ImageRef] = []
    var createdAt = Date()

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The Date header as a date, when it's in the usual RFC 5322 form.
    var sentDate: Date? { Self.parseRFC5322Date(date) }

    // MARK: - Building one

    /// From whatever was shared or pasted: a raw RFC 822 message, HTML, or plain text.
    static func from(raw: String) -> OrderEmail {
        if looksLikeMIME(raw) { return fromMIME(raw) }
        if looksLikeHTML(raw) { return fromHTML(raw) }
        return OrderEmail(text: tidy(raw))
    }

    static func fromHTML(_ html: String) -> OrderEmail {
        OrderEmail(text: HTMLText.text(from: html), images: HTMLText.images(in: html))
    }

    /// A whole message (.eml, or "show original"): headers, then a body that may be
    /// multipart, quoted-printable or base64. HTML is preferred over plain text
    /// because that's where the product pictures are.
    static func fromMIME(_ raw: String) -> OrderEmail {
        let message = MIMEPart(raw)
        var email = OrderEmail(text: "")
        email.subject = MIMEPart.decodeHeaderWords(message.header("subject"))
        email.from = MIMEPart.decodeHeaderWords(message.header("from"))
        email.date = message.header("date")

        let leaves = message.leaves()
        if let html = leaves.first(where: { $0.mediaType == "text/html" }) {
            let body = html.decodedBody()
            email.text = HTMLText.text(from: body)
            email.images = HTMLText.images(in: body)
        }
        if email.isEmpty, let plain = leaves.first(where: { $0.mediaType == "text/plain" }) {
            email.text = tidy(plain.decodedBody())
        }
        if email.isEmpty { email.text = tidy(message.decodedBody()) }
        return email
    }

    /// Whether shared text reads like a receipt rather than one wine — the share
    /// sheet uses this to offer the order import first.
    static func looksLikeOrder(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = ["order", "receipt", "invoice", "subtotal", "sub-total", "total",
                     "qty", "quantity", "shipped", "purchase", "confirmation"]
        let hits = words.filter { lower.contains($0) }.count
        let prices = lower.matches(of: #/[$€£]\s?\d[\d,]*(\.\d{2})?|\d+[.,]\d{2}\s?(usd|eur|gbp|€)/#).count
        return hits >= 2 && prices >= 1 || prices >= 3 && hits >= 1
    }

    static func looksLikeMIME(_ raw: String) -> Bool {
        let head = "\n" + raw.prefix(4000).lowercased()
        return head.contains("\ncontent-type:")
            && ["\nfrom:", "\nsubject:", "\nmime-version:", "\ndate:"].contains(where: head.contains)
    }

    static func looksLikeHTML(_ raw: String) -> Bool {
        let head = raw.prefix(2000).lowercased()
        return head.contains("<html") || head.contains("<body") || head.contains("<table")
            || head.contains("<div")
    }

    /// Collapses runs of blank lines and trailing spaces.
    static func tidy(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseRFC5322Date(_ raw: String) -> Date? {
        // Drop a trailing "(UTC)"-style comment.
        let value = raw.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

// MARK: - MIME

/// Just enough MIME to read an order email: headers, nested multiparts, and the
/// two transfer encodings mail actually uses.
struct MIMEPart {
    private(set) var headers: [(name: String, value: String)] = []
    private(set) var body: String = ""

    init(_ raw: String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let split = normalized.range(of: "\n\n")
        let headerBlock = split.map { String(normalized[..<$0.lowerBound]) } ?? normalized
        body = split.map { String(normalized[$0.upperBound...]) } ?? ""
        // Unfold continuation lines, then split name: value.
        var current: (String, String)?
        for line in headerBlock.components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t", current != nil {
                current!.1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let current { headers.append(current) }
            if let colon = line.firstIndex(of: ":") {
                current = (String(line[..<colon]).lowercased(),
                           String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            } else {
                current = nil
            }
        }
        if let current { headers.append(current) }
    }

    func header(_ name: String) -> String {
        headers.first { $0.name == name }?.value ?? ""
    }

    /// "text/html" from `Content-Type: text/html; charset=utf-8`.
    var mediaType: String {
        let value = header("content-type")
        let type = value.split(separator: ";").first.map(String.init) ?? ""
        return type.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty ?? "text/plain"
    }

    func parameter(_ name: String, of headerName: String = "content-type") -> String? {
        for piece in header(headerName).split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2, pair[0].lowercased() == name else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// The single-part pieces of this part, depth first.
    func leaves() -> [MIMEPart] {
        guard mediaType.hasPrefix("multipart/"), let boundary = parameter("boundary") else { return [self] }
        let delimiter = "--" + boundary
        var parts: [MIMEPart] = []
        let chunks = body.components(separatedBy: delimiter).dropFirst()
        for chunk in chunks {
            if chunk.hasPrefix("--") { break }
            let trimmed = chunk.hasPrefix("\n") ? String(chunk.dropFirst()) : chunk
            parts.append(contentsOf: MIMEPart(trimmed).leaves())
        }
        return parts
    }

    /// The body with its transfer encoding and charset undone.
    func decodedBody() -> String {
        let encoding = header("content-transfer-encoding").lowercased()
        let charset = Self.stringEncoding(parameter("charset"))
        switch encoding {
        case "base64":
            let compact = body.components(separatedBy: .whitespacesAndNewlines).joined()
            guard let data = Data(base64Encoded: compact, options: .ignoreUnknownCharacters) else { return body }
            return String(data: data, encoding: charset) ?? String(decoding: data, as: UTF8.self)
        case "quoted-printable":
            return Self.decodeQuotedPrintable(body, encoding: charset)
        default:
            return body
        }
    }

    static func decodeQuotedPrintable(_ text: String, encoding: String.Encoding, underscoreIsSpace: Bool = false) -> String {
        var bytes: [UInt8] = []
        let source = Array(text.utf8)
        var i = 0
        while i < source.count {
            let byte = source[i]
            if byte == UInt8(ascii: "=") {
                // Soft line break.
                if i + 1 < source.count, source[i + 1] == UInt8(ascii: "\n") { i += 2; continue }
                if i + 2 < source.count, source[i + 1] == UInt8(ascii: "\r"), source[i + 2] == UInt8(ascii: "\n") {
                    i += 3; continue
                }
                if i + 2 < source.count,
                   let hex = UInt8(String(decoding: source[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(hex)
                    i += 3
                    continue
                }
            }
            bytes.append(underscoreIsSpace && byte == UInt8(ascii: "_") ? UInt8(ascii: " ") : byte)
            i += 1
        }
        let data = Data(bytes)
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    /// RFC 2047 encoded words in a header: `=?utf-8?Q?Your_order?=`.
    static func decodeHeaderWords(_ value: String) -> String {
        let pattern = #/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/#
        // Whitespace between adjacent encoded words isn't part of the text.
        let joined = value.replacing(#/\?=\s+=\?/#, with: "?==?")
        return joined.replacing(pattern) { match in
            let encoding = stringEncoding(String(match.1))
            let payload = String(match.3)
            if match.2.lowercased() == "b" {
                guard let data = Data(base64Encoded: payload) else { return payload }
                return String(data: data, encoding: encoding) ?? payload
            }
            return decodeQuotedPrintable(payload, encoding: encoding, underscoreIsSpace: true)
        }
    }

    static func stringEncoding(_ charset: String?) -> String.Encoding {
        switch charset?.lowercased() {
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        case "us-ascii", "ascii": return .ascii
        case "utf-16": return .utf16
        default: return .utf8
        }
    }
}

// MARK: - HTML

/// Turns an HTML email into readable text, and lists the pictures it shows.
enum HTMLText {
    static func text(from html: String) -> String {
        var s = html
        // Things that never hold order text.
        for tag in ["head", "style", "script", "title"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        // Links: keep where a product line points, since that's its "where to buy".
        s = s.replacingOccurrences(
            of: #"<a\b[^>]*href\s*=\s*["'](https://[^"'\s]{1,300})["'][^>]*>([\s\S]*?)</a>"#,
            with: "$2 [$1]", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<(br|/p|/div|/tr|/li|/h[1-6]|/table)\\b[^>]*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</t[dh]>", with: "\t",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        let lines = s.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        // Drop link-only lines from tracking footers that carry no words.
        let kept = lines.filter { line in
            !(line.hasPrefix("[https://") && line.hasSuffix("]") && !line.contains(" "))
        }
        return OrderEmail.tidy(kept.joined(separator: "\n"))
    }

    /// `<img>` pictures worth offering as product photos: https only, not 1×1
    /// tracking pixels, spacers or obvious logos/icons.
    static func images(in html: String) -> [OrderEmail.ImageRef] {
        var seen = Set<String>()
        var result: [OrderEmail.ImageRef] = []
        for match in html.matches(of: #/<img\b[^>]*>/#.ignoresCase()) {
            let tag = String(match.0)
            guard let src = attribute("src", in: tag).map(decodeEntities),
                  src.lowercased().hasPrefix("https://"), seen.insert(src).inserted else { continue }
            let width = attribute("width", in: tag).flatMap { Int($0.filter(\.isNumber)) }
            let height = attribute("height", in: tag).flatMap { Int($0.filter(\.isNumber)) }
            if let width, width < 40 { continue }
            if let height, height < 40 { continue }
            let alt = attribute("alt", in: tag).map(decodeEntities) ?? ""
            let lower = (src + " " + alt).lowercased()
            if ["logo", "icon", "spacer", "pixel", "facebook", "instagram", "twitter", "pinterest",
                "badge", "social", "tracking", "open.gif", "beacon"].contains(where: lower.contains) { continue }
            result.append(.init(url: src, alt: alt.trimmingCharacters(in: .whitespaces)))
        }
        return Array(result.prefix(40))
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 2...4 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "eacute": "é", "egrave": "è", "ecirc": "ê", "agrave": "à", "acirc": "â",
            "ocirc": "ô", "ucirc": "û", "uuml": "ü", "ouml": "ö", "auml": "ä", "ccedil": "ç",
            "ntilde": "ñ", "iuml": "ï", "euro": "€", "pound": "£", "copy": "©", "reg": "®",
            "trade": "™", "ndash": "–", "mdash": "—", "rsquo": "’", "lsquo": "‘",
            "rdquo": "”", "ldquo": "“", "hellip": "…", "times": "×", "middot": "·",
        ]
        return text.replacing(#/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/#) { match in
            let body = String(match.1)
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } ?? String(match.0)
            }
            if body.hasPrefix("#") {
                return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) } ?? String(match.0)
            }
            return named[body.lowercased()] ?? String(match.0)
        }
    }
}

// MARK: - Waiting orders (share extension → app)

/// Order emails shared into Vino Cellar wait here, next to `SharedImportStore`'s
/// single wines, until the app opens them for review.
enum SharedOrderStore {
    static func folder(baseURL: URL? = nil) -> URL? {
        let base = baseURL ?? FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedImportStore.appGroup)
        guard let dir = base?.appendingPathComponent("PendingOrders", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ email: OrderEmail, baseURL: URL? = nil) throws {
        guard let dir = folder(baseURL: baseURL) else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(email)
            .write(to: dir.appendingPathComponent("\(email.id.uuidString).json"), options: .atomic)
    }

    /// Waiting orders, oldest first.
    static func load(baseURL: URL? = nil) -> [OrderEmail] {
        guard let dir = folder(baseURL: baseURL),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(OrderEmail.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func remove(_ email: OrderEmail, baseURL: URL? = nil) {
        guard let dir = folder(baseURL: baseURL) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(email.id.uuidString).json"))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
