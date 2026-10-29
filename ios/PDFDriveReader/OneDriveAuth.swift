import AuthenticationServices
import CryptoKit
import Foundation
import Security

enum AuthError: LocalizedError {
    case missingClientID
    case notSignedIn
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: return "Enter your Application (client) ID in Settings first."
        case .notSignedIn: return "Sign in to OneDrive on your iPhone."
        case .failed(let message): return message
        }
    }
}

/// Microsoft sign-in using OAuth 2.0 authorization code + PKCE (no SDK needed).
/// The refresh token lives in the Keychain so the app can reach OneDrive from
/// CarPlay while the phone is locked.
@MainActor
final class OneDriveAuth: ObservableObject {
    static let shared = OneDriveAuth()

    static let callbackScheme = "pdfdrivereader"
    static let redirectURI = "pdfdrivereader://auth"
    private static let authority = "https://login.microsoftonline.com/common/oauth2/v2.0"
    private static let scope = "Files.Read offline_access"

    @Published private(set) var isSignedIn: Bool

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshTask: Task<String, Error>?
    private var webSession: ASWebAuthenticationSession?
    private var anchorProvider: AnchorProvider?

    private init() {
        isSignedIn = Keychain.get("refreshToken") != nil
    }

    func signIn(from anchor: ASPresentationAnchor) async throws {
        guard !AppSettings.shared.clientID.isEmpty else { throw AuthError.missingClientID }

        let verifier = Self.base64URL(Self.randomBytes(32))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: Self.authority + "/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppSettings.shared.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]

        let provider = AnchorProvider(anchor)
        anchorProvider = provider
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: Self.callbackScheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? AuthError.failed("Sign-in was cancelled."))
                }
            }
            session.presentationContextProvider = provider
            self.webSession = session
            session.start()
        }
        webSession = nil
        anchorProvider = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let message = items.first(where: { $0.name == "error_description" })?.value {
            throw AuthError.failed(message)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.failed("Microsoft didn't return a sign-in code.")
        }
        try await redeem(["grant_type": "authorization_code", "code": code, "code_verifier": verifier])
        isSignedIn = true
    }

    func signOut() {
        Keychain.set(nil, for: "refreshToken")
        accessToken = nil
        expiry = .distantPast
        isSignedIn = false
    }

    /// A valid access token, refreshed when needed.
    func token() async throws -> String {
        if let accessToken, expiry > Date().addingTimeInterval(60) { return accessToken }
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = Keychain.get("refreshToken") else { throw AuthError.notSignedIn }
        let task = Task { try await self.redeem(["grant_type": "refresh_token", "refresh_token": refresh]) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    @discardableResult
    private func redeem(_ params: [String: String]) async throws -> String {
        var form = params
        form["client_id"] = AppSettings.shared.clientID
        form["redirect_uri"] = Self.redirectURI
        form["scope"] = Self.scope

        var request = URLRequest(url: URL(string: Self.authority + "/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let access = response.access_token else {
            if response.error == "invalid_grant" { signOut() }
            throw AuthError.failed(response.error_description ?? "Couldn't get access to OneDrive.")
        }
        accessToken = access
        expiry = Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600))
        if let refresh = response.refresh_token { Keychain.set(refresh, for: "refreshToken") }
        return access
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
        let error: String?
        let error_description: String?
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(_ anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PDFDriveReader",
            kSecAttrAccount as String: key,
        ]
    }

    static func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        // Readable while the phone is locked (e.g. driving with CarPlay).
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
