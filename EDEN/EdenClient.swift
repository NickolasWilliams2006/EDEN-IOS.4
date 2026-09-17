import Foundation
import Combine
import AVFoundation
import CryptoKit
import Security

/// Transport rules that never change per request:
///
/// - A pairing credential must never follow a redirect to another server.
/// - The server's self-signed certificate is accepted only when it is the
///   exact one the pairing link named (f=). Safari lets a person tap past a
///   certificate warning; URLSession does not, and installing the cert as a
///   trusted root on the phone is a step nobody gets right the first time.
///   Pinning the fingerprint from the link is stricter than either, and the
///   only way a mismatch is handled is refusal.
/// - With no fingerprint (an older link) the system's trust decision stands.
private final class EdenTransportPolicy: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    /// Lowercase hex SHA-256 of the pinned certificate's DER bytes, or nil.
    var fingerprint: String?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let expected = fingerprint else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let offered = Self.sha256Hex(SecCertificateCopyData(leaf) as Data)
        if offered == expected {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Talks to the EDEN Python server on your machine.
///
/// The app is a client, not a rewrite: indexing, the model, tools, memory and
/// guardrails all stay on the server. Only Bluetooth and the UI are native,
/// because those are the parts iOS won't let a web page do.
@MainActor
final class EdenClient: NSObject, ObservableObject {

    struct Turn: Identifiable {
        let id = UUID()
        let mine: Bool
        let text: String
        let tools: [String]
    }

    @Published var host: String = UserDefaults.standard.string(forKey: "eden.host")
        ?? ""
    @Published var turns: [Turn] = []
    @Published var busy = false
    @Published var connectionNote: String?

    private var player: AVAudioPlayer?
    private var recorder: AVAudioRecorder?
    private let synthesizer = AVSpeechSynthesizer()
    private let transportPolicy = EdenTransportPolicy()
    private lazy var session = URLSession(configuration: .ephemeral,
                                          delegate: transportPolicy, delegateQueue: nil)

    override init() {
        super.init()
        transportPolicy.fingerprint = Self.storedFingerprint(origin: host)
    }

    /// The fingerprint is not a secret — it is public on every TLS handshake —
    /// so it lives in preferences beside the origin, keyed per server.
    private static func fingerprintKey(origin: String) -> String { "eden.fingerprint:" + origin }

    static func storedFingerprint(origin: String) -> String? {
        let value = UserDefaults.standard.string(forKey: fingerprintKey(origin: origin)) ?? ""
        return value.isEmpty ? nil : value
    }

    var pinned: Bool { transportPolicy.fingerprint != nil }

    @Published var pairingNote: String?

    /// Whether Talk can work at all right now, and if not, why.
    var readiness: String {
        if host.isEmpty { return "Not paired. Paste EDEN's link below." }
        if accessToken(origin: host).isEmpty { return "Paired without a token. Paste EDEN's full link." }
        return pinned ? "Ready — certificate pinned" : "Ready — relying on iOS certificate trust"
    }

    func saveHost(_ value: String) {
        if let why = PairingLink.problem(value) {
            pairingNote = why
            connectionNote = "Pairing failed — see Setup"
            return
        }
        guard let pairing = PairingLink(value) else {
            pairingNote = "That link could not be read."
            return
        }
        pairingNote = nil
        let token = pairing.token
        let origin = pairing.origin
        if let token, !token.isEmpty, !storeToken(token, origin: origin) {
            connectionNote = "Couldn't save the pairing token in Keychain."
            return
        }
        host = origin
        UserDefaults.standard.set(host, forKey: "eden.host")
        // A fresh link always replaces the pin; a link without one clears it
        // rather than silently keeping a pin from a server that may have
        // regenerated its certificate since.
        UserDefaults.standard.set(pairing.fingerprint ?? "", forKey: Self.fingerprintKey(origin: origin))
        transportPolicy.fingerprint = pairing.fingerprint
        objectWillChange.send()
        if accessToken(origin: host).isEmpty {
            connectionNote = "Paste the full pairing link, including ?t=…"
        } else if pairing.fingerprint == nil {
            connectionNote = "Paired without a certificate pin. Restart EDEN and paste its new link (with f=), "
                + "or trust its certificate in Settings › General › About › Certificate Trust Settings."
        } else {
            connectionNote = nil
        }
    }

    private func tokenQuery(origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "EDEN LAN pairing", kSecAttrAccount as String: origin]
    }

    private func storeToken(_ token: String, origin: String) -> Bool {
        let query = tokenQuery(origin: origin)
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = query.merging(values) { _, value in value }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func accessToken(origin: String) -> String {
        var query = tokenQuery(origin: origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Ask

    func ask(_ text: String, speakReply: Bool = true) async {
        guard !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        turns.append(Turn(mine: true, text: text, tools: []))
        busy = true
        defer { busy = false }

        do {
            let body = try JSONSerialization.data(withJSONObject: ["text": text])
            let json = try await post("/api/ask", body: body, contentType: "application/json")
            let spoken = json["spoken"] as? String ?? "(no reply)"
            let tools = json["tools_used"] as? [String] ?? []
            turns.append(Turn(mine: false, text: spoken, tools: tools))
            connectionNote = nil
            if speakReply { await speak(spoken) }
        } catch {
            connectionNote = friendly(error)
            turns.append(Turn(mine: false, text: friendly(error), tools: []))
        }
    }

    /// Hand a Bluetooth reading to EDEN so it can reason about it against
    /// your own files.
    func reportReading(device: String, characteristic: String, value: String) async {
        await ask("A Bluetooth device, \(device), reported \(value) on characteristic "
                  + "\(characteristic). What does that suggest?", speakReply: true)
    }

    // MARK: - Voice

    func speak(_ text: String) async {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["text": text])
            let data = try await postRaw("/api/speak", body: body, contentType: "application/json")
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player?.stop()
            synthesizer.stopSpeaking(at: .immediate)
            if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               result["browser"] as? Bool == true {
                synthesizer.speak(AVSpeechUtterance(string: text))
                return
            }
            player = try AVAudioPlayer(data: data)
            guard player?.play() == true else { throw Failure.server("Audio playback did not start.") }
        } catch {
            connectionNote = "Couldn't speak: \(friendly(error))"
        }
    }

    func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        player?.stop()
        synthesizer.stopSpeaking(at: .immediate)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eden-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let candidate = try AVAudioRecorder(url: url, settings: settings)
        guard candidate.record() else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.server("Recording did not start. Allow EDEN microphone access in Settings.")
        }
        recorder = candidate
    }

    func stopRecordingAndSend() async {
        guard let recorder else { return }
        recorder.stop()
        let url = recorder.url
        defer { try? FileManager.default.removeItem(at: url) }
        self.recorder = nil
        busy = true
        defer { busy = false }
        do {
            let audio = try Data(contentsOf: url)
            let json = try await post("/api/listen", body: audio, contentType: "audio/wav")
            if let text = json["text"] as? String, !text.isEmpty {
                busy = false
                await ask(text)
            }
        } catch {
            connectionNote = "Transcription failed: \(friendly(error))"
        }
    }

    // MARK: - Transport

    private func post(_ path: String, body: Data, contentType: String) async throws -> [String: Any] {
        let data = try await postRaw(path, body: body, contentType: contentType)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let err = json["error"] as? String { throw Failure.server(err) }
        return json
    }

    private func postRaw(_ path: String, body: Data, contentType: String) async throws -> Data {
        guard let url = URL(string: host + path), url.scheme == "https",
              url.host != nil else { throw Failure.badHost }
        let token = accessToken(origin: host)
        guard !token.isEmpty else { throw Failure.server("Pair this phone in Setup using EDEN's full ?t= link.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Eden-Token")
        req.httpBody = body
        req.timeoutInterval = 300
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? String {
                throw Failure.server(err)
            }
            throw Failure.server("Server returned \(http.statusCode)")
        }
        return data
    }

    enum Failure: LocalizedError {
        case badHost
        case server(String)
        var errorDescription: String? {
            switch self {
            case .badHost:        return "That server address isn't valid."
            case .server(let m):  return m
            }
        }
    }

    private func friendly(_ error: Error) -> String {
        if let f = error as? Failure { return f.localizedDescription }
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
            return "Can't reach EDEN at \(host). Is it running with --lan, and are you on the same Wi-Fi?"
        case NSURLErrorCancelled, NSURLErrorUserCancelledAuthentication:
            return "EDEN's certificate doesn't match the one you paired with. Restart EDEN and paste its new link."
        case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateHasBadDate:
            return pinned
                ? "EDEN's certificate doesn't match the one you paired with. Restart EDEN and paste its new link."
                : "Certificate not trusted. Re-pair with EDEN's current link (it carries the certificate fingerprint)."
        default:
            return ns.localizedDescription
        }
    }
}
