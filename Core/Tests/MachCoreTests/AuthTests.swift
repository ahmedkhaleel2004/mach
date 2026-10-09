import XCTest
@testable import MachCore

/// Sign-in with both kinds of Google key, as far as it goes without Google: the key file's shapes, the page that is
/// opened, the reply that comes back, and what is sent for tokens.
final class AuthTests: XCTestCase {
    private let phoneId = "1234-abcd.apps.googleusercontent.com"
    private var phone: OAuthClient { OAuthClient(clientId: phoneId, clientSecret: nil) }
    private let desktop = OAuthClient(clientId: "9876-wxyz.apps.googleusercontent.com", clientSecret: "shh")

    private func body(_ request: URLRequest) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            fields[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return fields
    }

    func testKeyFileShapes() throws {
        let google = Data(#"{"installed":{"client_id":"9876-wxyz.apps.googleusercontent.com","project_id":"p","client_secret":"shh","redirect_uris":["http://localhost"]}}"#.utf8)
        for kind in [OAuthClient.Kind.desktop, .phone] {
            let client = try XCTUnwrap(OAuthClient.load(from: google, for: kind))
            XCTAssertEqual(client.clientId, desktop.clientId)
            XCTAssertEqual(client.clientSecret, "shh")
            XCTAssertFalse(client.worksOnPhone)
        }

        let small = Data(#"{"client_id":"1234-abcd.apps.googleusercontent.com"}"#.utf8)
        for kind in [OAuthClient.Kind.desktop, .phone] {
            let client = try XCTUnwrap(OAuthClient.load(from: small, for: kind))
            XCTAssertEqual(client.clientId, phoneId)
            XCTAssertNil(client.clientSecret)
            XCTAssertTrue(client.worksOnPhone)
        }

        // One file for a checkout that builds both apps: each platform takes its own key.
        let both = Data(#"{"installed":{"client_id":"9876-wxyz.apps.googleusercontent.com","client_secret":"shh"},"ios":{"client_id":"1234-abcd.apps.googleusercontent.com"}}"#.utf8)
        XCTAssertEqual(OAuthClient.load(from: both, for: .desktop)?.clientSecret, "shh")
        let onPhone = try XCTUnwrap(OAuthClient.load(from: both, for: .phone))
        XCTAssertEqual(onPhone.clientId, phoneId)
        XCTAssertNil(onPhone.clientSecret)

        // The property list Google offers for an iOS client.
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CLIENT_ID": phoneId, "REVERSED_CLIENT_ID": "com.googleusercontent.apps.1234-abcd", "BUNDLE_ID": "x.y"], format: .xml, options: 0)
        XCTAssertEqual(OAuthClient.load(from: plist, for: .phone)?.clientId, phoneId)

        // Our own shape, which is also how a key is kept beside a saved sign-in.
        let own = try JSONEncoder().encode(desktop)
        XCTAssertEqual(OAuthClient.load(from: own, for: .phone)?.clientSecret, "shh")

        XCTAssertNil(OAuthClient.load(from: Data("{}".utf8)))
        XCTAssertNil(OAuthClient.load(from: Data(#"{"client_id":""}"#.utf8)))
        XCTAssertNil(OAuthClient.load(from: Data("not a key".utf8)))
    }

    func testPhoneRedirect() {
        XCTAssertEqual(phone.redirectScheme, "com.googleusercontent.apps.1234-abcd")
        XCTAssertEqual(OAuth.phoneRedirect(for: phone), "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
        XCTAssertTrue(phone.worksOnPhone)
        XCTAssertFalse(desktop.worksOnPhone)
        XCTAssertNil(OAuthClient(clientId: "bench.invalid", clientSecret: nil).redirectScheme)
        XCTAssertNil(OAuthClient(clientId: ".apps.googleusercontent.com", clientSecret: nil).redirectScheme)
        XCTAssertFalse(OAuthClient(clientId: "", clientSecret: nil).worksOnPhone)
    }

    func testSignInPage() throws {
        let redirect = try XCTUnwrap(OAuth.phoneRedirect(for: phone))
        let url = OAuth.authorizationURL(client: phone, redirect: redirect, challenge: "CH", state: "ST", loginHint: "a@b.c", scope: OAuth.scope)
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
        let query = OAuth.callbackParameters(url)
        XCTAssertEqual(query["client_id"], phoneId)
        XCTAssertEqual(query["redirect_uri"], "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["code_challenge"], "CH")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["state"], "ST")
        XCTAssertEqual(query["login_hint"], "a@b.c")
        XCTAssertEqual(query["scope"], OAuth.scope)
        XCTAssertNil(query["client_secret"])
        // SHA-256, then base64 for URLs with no padding. The expected value is from `openssl dgst -sha256 -binary | base64`.
        XCTAssertEqual(OAuth.challenge(for: "dBjftJeZ4CVP-mBKWI1WWAH3BtP4gqzBrGTDFqZMT5k"), "_zt_Zya4cdDYYkh1fNGKPjWIVduceDzS3awiJKbXVvk")
    }

    func testReplyFromGoogle() throws {
        let reply = try XCTUnwrap(URL(string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=ST&code=4%2F0Ab_c-d&scope=a%20b"))
        let parameters = OAuth.callbackParameters(reply)
        XCTAssertEqual(try OAuth.code(from: parameters, state: "ST"), "4/0Ab_c-d")
        // A reply to some other attempt, or one that somebody else made up, is refused.
        XCTAssertThrowsError(try OAuth.code(from: parameters, state: "other"))
        let refused = OAuth.callbackParameters(try XCTUnwrap(URL(string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect?state=ST&error=access_denied")))
        XCTAssertThrowsError(try OAuth.code(from: refused, state: "ST")) { XCTAssertEqual($0.localizedDescription, "Sign-in was cancelled.") }
        XCTAssertThrowsError(try OAuth.code(from: [:], state: "ST"))
    }

    func testTokenRequests() {
        let redirect = "com.googleusercontent.apps.1234-abcd:/oauth2redirect"
        let code = body(OAuth.formRequest("https://oauth2.googleapis.com/token", OAuth.codeForm(client: phone, code: "4/0A b+c", redirect: redirect, verifier: "VER")))
        XCTAssertEqual(code, ["grant_type": "authorization_code", "code": "4/0A b+c", "client_id": phoneId, "redirect_uri": redirect, "code_verifier": "VER"])

        let refresh = body(OAuth.formRequest("https://oauth2.googleapis.com/token", OAuth.refreshForm(client: phone, refreshToken: "1//r")))
        XCTAssertEqual(refresh, ["grant_type": "refresh_token", "refresh_token": "1//r", "client_id": phoneId])

        // A Desktop key still sends its secret, as before.
        XCTAssertEqual(OAuth.codeForm(client: desktop, code: "c", redirect: "http://127.0.0.1:5000", verifier: "v")["client_secret"], "shh")
        XCTAssertEqual(OAuth.refreshForm(client: desktop, refreshToken: "r")["client_secret"], "shh")

        let request = OAuth.formRequest("https://oauth2.googleapis.com/token", ["a": "x y&z=1/2"])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self), "a=x%20y%26z%3D1%2F2")
    }

    func testRevokeRequest() {
        let request = OAuth.revokeRequest("1//refresh")
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(body(request), ["token": "1//refresh"])
    }

    /// The whole iPhone flow up to the point Google would be asked for tokens: a Desktop key is refused before any
    /// page is shown, and a reply that does not answer this attempt never reaches Google.
    func testPhoneSignInRefusals() async {
        do {
            _ = try await OAuth.signIn(client: desktop, present: { _, _ in XCTFail("no page for a Desktop key"); return URL(string: "x:/")! })
            XCTFail("a Desktop key signed in on the phone flow")
        } catch {}

        let shown = Shown()
        do {
            _ = try await OAuth.signIn(client: phone, loginHint: "a@b.c", present: { page, scheme in
                shown.set(page, scheme)
                return URL(string: "\(scheme):/oauth2redirect?state=forged&code=x")!
            })
            XCTFail("a forged reply was accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The sign-in reply did not match the request.")
        }
        XCTAssertEqual(shown.scheme, "com.googleusercontent.apps.1234-abcd")
        let query = OAuth.callbackParameters(shown.page ?? URL(string: "x:/")!)
        XCTAssertEqual(query["redirect_uri"], "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
        XCTAssertEqual(query["state"]?.count, 24)
        XCTAssertEqual(query["code_challenge"]?.count, 43)
    }
}

private final class Shown: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var page: URL?
    private(set) var scheme: String?
    func set(_ page: URL, _ scheme: String) { lock.withLock { self.page = page; self.scheme = scheme } }
}
