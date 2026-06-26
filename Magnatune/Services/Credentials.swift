import Foundation
import Security

/// Stores the Magnatune membership login in the Keychain (never in source/UserDefaults).
final class Credentials: ObservableObject {
    private let service = "com.magnatune.player.membership"
    private let account = "membership"

    @Published var username: String = ""
    @Published private(set) var hasPassword: Bool = false

    /// Verified membership status. Membership is checked ONCE at launch (see
    /// `refreshMembership()`) and whenever credentials change in Settings — never per
    /// media request. Streaming then just fetches the right file for this status straight
    /// from he3 with no auth (member → clean `.m4a`, non-member → `_spoken.m4a`).
    /// Initialised optimistically from stored credentials so a returning member streams
    /// the clean file immediately; the launch re-verify downgrades an expired membership.
    @Published private(set) var isMember: Bool = false

    init() {
        username = UserDefaults.standard.string(forKey: "membership.username") ?? ""
        hasPassword = (readPassword() != nil)
        isMember = !username.isEmpty && hasPassword
    }

    func save(username: String, password: String) {
        self.username = username
        UserDefaults.standard.set(username, forKey: "membership.username")
        writePassword(password)
        hasPassword = !password.isEmpty
        // save() is only called by Settings after a successful server verify.
        isMember = !username.isEmpty && !password.isEmpty
    }

    func clear() {
        username = ""
        UserDefaults.standard.removeObject(forKey: "membership.username")
        deletePassword()
        hasPassword = false
        isMember = false
    }

    /// Re-verify the stored membership against the server, updating `isMember`.
    /// Called once at launch and after a credential change. A network failure leaves the
    /// previous status untouched (a flaky connection must not sign a real member out).
    @MainActor
    func refreshMembership() async {
        guard !username.isEmpty, let pw = readPassword(), !pw.isEmpty else {
            isMember = false
            return
        }
        switch await Credentials.membershipStatus(username: username, password: pw) {
        case .member:      isMember = true
        case .notMember:   isMember = false
        case .unreachable: break          // keep last-known status on a network blip
        }
    }

    /// Authorization header value for HTTP Basic auth, or nil if not a member.
    func basicAuthHeader() -> String? {
        guard !username.isEmpty, let pw = readPassword(), !pw.isEmpty else { return nil }
        let token = Data("\(username):\(pw)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    func password() -> String? { readPassword() }

    /// Outcome of a membership check: a definite server verdict, or `unreachable` when
    /// the network prevented a verdict (so callers can avoid signing a member out on a blip).
    enum MembershipStatus { case member, notMember, unreachable }

    /// Check a username/password against the membership-protected endpoint.
    /// 200 ⇒ `.member`, any other response ⇒ `.notMember`, network failure ⇒ `.unreachable`.
    static func membershipStatus(username: String, password: String) async -> MembershipStatus {
        guard !username.isEmpty, !password.isEmpty,
              let url = URL(string: "http://download.magnatune.com/buy/membership_free_dl_xml")
        else { return .notMember }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200 ? .member : .notMember
        } catch {
            return .unreachable
        }
    }

    /// Verify a username/password. Returns true only on a definite server acceptance
    /// (HTTP 200) — used by the Settings sign-in flow, which must not save on failure.
    static func verify(username: String, password: String) async -> Bool {
        await membershipStatus(username: username, password: password) == .member
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
