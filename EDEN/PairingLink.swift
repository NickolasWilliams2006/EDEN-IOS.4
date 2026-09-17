import Foundation

/// Parse separately from Keychain/UI so credentials never become a saved URL.
struct PairingLink {
    let origin: String
    let token: String?
    /// SHA-256 of the server's certificate (DER), lowercase hex. EDEN prints it
    /// as f= so the app can pin its self-signed cert without iOS trust settings.
    let fingerprint: String?

    /// What EDEN printed, however it arrived: the bare link, the whole console
    /// line ("https://…   <- from your phone"), or the eden:// handoff the web
    /// page offers, which is the same link with its scheme swapped.
    static func extract(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "https://") ?? text.range(of: "eden://") {
            text = String(text[range.lowerBound...])
        }
        if let end = text.firstIndex(where: { $0.isWhitespace || $0 == "<" }) {
            text = String(text[..<end])
        }
        if text.lowercased().hasPrefix("eden://") {
            text = "https://" + text.dropFirst("eden://".count)
        }
        return text
    }

    /// Why `init?` would refuse this, in words a person can act on.
    static func problem(_ raw: String) -> String? {
        let value = extract(raw)
        if value.isEmpty { return "Nothing to pair with. Paste the link EDEN printed." }
        guard let parts = URLComponents(string: value) else { return "That isn't a link EDEN would print." }
        if parts.scheme?.lowercased() != "https" {
            return "The link must start with https://. EDEN needs its certs/ folder to serve HTTPS."
        }
        if (parts.host ?? "").isEmpty { return "The link has no server address." }
        let items = parts.queryItems ?? []
        let tokens = items.filter { $0.name == "t" }
        if tokens.count != 1 || (tokens.first?.value ?? "").isEmpty {
            return "The link is missing its ?t= token. Copy the whole line EDEN printed."
        }
        let prints = items.filter { $0.name == "f" }
        if prints.count > 1 { return "The link has two f= values." }
        if let f = prints.first?.value, f.count != 64 || !f.allSatisfy({ $0.isHexDigit }) {
            return "The certificate fingerprint (f=) is \(f.count) characters; it should be 64. Copy the whole link."
        }
        return PairingLink(value) == nil ? "That link has something EDEN never prints in it." : nil
    }

    init?(_ value: String) {
        guard var parts = URLComponents(string: PairingLink.extract(value)),
              parts.scheme?.lowercased() == "https",
              let hostname = parts.host, !hostname.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        let tokens = (parts.queryItems ?? []).filter { $0.name == "t" }
        guard tokens.count <= 1 else { return nil }
        let prints = (parts.queryItems ?? []).filter { $0.name == "f" }
        guard prints.count <= 1 else { return nil }
        if let item = prints.first {
            let value = (item.value ?? "").lowercased()
            guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { return nil }
            fingerprint = value
        } else {
            fingerprint = nil
        }
        if let item = tokens.first {
            guard let value = item.value, !value.isEmpty,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            token = value
        } else {
            token = nil
        }
        parts.scheme = "https"
        parts.host = hostname.lowercased()
        parts.query = nil
        parts.fragment = nil
        parts.path = ""
        guard let url = parts.url else { return nil }
        origin = url.absoluteString
    }
}
