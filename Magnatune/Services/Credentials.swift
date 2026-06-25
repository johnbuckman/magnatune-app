import Foundation
import Security

/// Stores the Magnatune membership login in the Keychain (never in source/UserDefaults).
final class Credentials: ObservableObject {
    private let service = "com.magnatune.player.membership"
    private let account = "membership"

    @Published var username: String = ""
    @Published private(set) var hasPassword: Bool = false

    init() {
        username = UserDefaults.standard.string(forKey: "membership.username") ?? ""
        hasPassword = (readPassword() != nil)
    }

    var isMember: Bool { !username.isEmpty && hasPassword }

    func save(username: String, password: String) {
        self.username = username
        UserDefaults.standard.set(username, forKey: "membership.username")
        writePassword(password)
        hasPassword = !password.isEmpty
    }

    func clear() {
        username = ""
        UserDefaults.standard.removeObject(forKey: "membership.username")
        deletePassword()
        hasPassword = false
    }

    /// Authorization header value for HTTP Basic auth, or nil if not a member.
    func basicAuthHeader() -> String? {
        guard !username.isEmpty, let pw = readPassword(), !pw.isEmpty else { return nil }
        let token = Data("\(username):\(pw)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    func password() -> String? { readPassword() }

    /// Verify a username/password against a membership-protected endpoint.
    /// Returns true only if the server accepts the credentials (HTTP 200).
    static func verify(username: String, password: String) async -> Bool {
        guard !username.isEmpty, !password.isEmpty,
              let url = URL(string: "http://download.magnatune.com/buy/membership_free_dl_xml")
        else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: Keychain primitives

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func readPassword() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writePassword(_ password: String) {
        deletePassword()
        var q = baseQuery()
        q[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    private func deletePassword() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
