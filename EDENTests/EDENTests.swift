import XCTest
@testable import EDEN

final class EDENTests: XCTestCase {
    func testPairingSeparatesCredentialsFromOrigin() throws {
        let link = try XCTUnwrap(PairingLink("  https://EDEN.local:8765/?t=secret%2Btoken#discard  "))
        XCTAssertEqual(link.origin, "https://eden.local:8765")
        XCTAssertEqual(link.token, "secret+token")
        XCTAssertFalse(link.origin.contains("secret"))
    }

    func testOriginWithoutTokenCanReuseKeychainEntry() throws {
        let link = try XCTUnwrap(PairingLink("https://eden.local:8765"))
        XCTAssertNil(link.token)
        XCTAssertNil(link.fingerprint)
    }

    func testPairingCarriesCertificateFingerprint() throws {
        let hex = String(repeating: "ab", count: 32)
        let link = try XCTUnwrap(PairingLink("https://10.0.0.5:8765/?t=tok&f=" + hex.uppercased()))
        XCTAssertEqual(link.fingerprint, hex)
        XCTAssertEqual(link.token, "tok")
        XCTAssertEqual(link.origin, "https://10.0.0.5:8765")
        XCTAssertFalse(link.origin.contains("f="))
    }

    func testPairingExtractsLinkFromConsoleLineAndAppScheme() throws {
        let hex = String(repeating: "ab", count: 32)
        let line = "  https://10.0.0.5:8765/?t=tok&f=" + hex + "   <- from your phone\n"
        XCTAssertEqual(try XCTUnwrap(PairingLink(line)).token, "tok")
        XCTAssertEqual(try XCTUnwrap(PairingLink("eden://10.0.0.5:8765/?t=tok&f=" + hex)).origin, "https://10.0.0.5:8765")
        XCTAssertEqual(try XCTUnwrap(PairingLink("eden://10.0.0.5:8765/?t=tok&f=" + hex)).fingerprint, hex)
        XCTAssertNil(PairingLink.problem(line))
    }

    func testPairingProblemsAreNamed() {
        XCTAssertNotNil(PairingLink.problem(""))
        XCTAssertTrue(PairingLink.problem("http://10.0.0.5:8765/?t=tok")!.contains("https"))
        XCTAssertTrue(PairingLink.problem("https://10.0.0.5:8765/")!.contains("?t="))
        XCTAssertTrue(PairingLink.problem("https://10.0.0.5:8765/?t=tok&f=abc")!.contains("64"))
    }

    func testPairingRejectsMalformedFingerprint() {
        for f in ["", "abc", String(repeating: "zz", count: 32), String(repeating: "ab", count: 31)] {
            XCTAssertNil(PairingLink("https://eden.local?t=x&f=" + f), f)
        }
        XCTAssertNil(PairingLink("https://eden.local?t=x&f=" + String(repeating: "ab", count: 32)
                                 + "&f=" + String(repeating: "cd", count: 32)))
    }

    func testPairingRejectsUnsafeOrAmbiguousLinks() {
        for value in ["http://eden.local?t=x", "file:///tmp/x", "https://u:p@eden.local?t=x",
                      "https://eden.local/api/ask?t=x", "https://eden.local?t=x&t=y",
                      "https://eden.local?t=", "https://eden.local?t=x%0Ay", "https://eden.local:0?t=x"] {
            XCTAssertNil(PairingLink(value), value)
        }
    }

    func testBluetoothHexParser() {
        XCTAssertEqual(Data(hexString: "0x01 aF 02"), Data([1, 175, 2]))
        XCTAssertNil(Data(hexString: "abc"))
        XCTAssertNil(Data(hexString: "zz"))
    }
}
