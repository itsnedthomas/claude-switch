import CryptoKit
import Foundation

/// A login Claude Switch made itself through the browser, for Cursor or Codex.
/// Kept in the Keychain, never on disk.
struct ProviderLogin: Codable, Equatable {
    var access: String
    var refresh: String?
    var idToken: String?
    /// When `access` stops working, if known.
    var expires: Date?
    /// Cursor: the user id the session cookie needs. Codex: the ChatGPT account id.
    var accountID: String?
    var email: String?
    var name: String?
    var plan: String?
}

enum PKCE {
    /// Random URL-safe string.
    static func random(_ bytes: Int = 32) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return base64url(Data(b))
    }

    static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
