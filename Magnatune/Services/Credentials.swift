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
    /// media request. It decides WHICH file to request (member → clean Opus,
    /// non-member → the free `_spoken.m4a`); the clean file is then HTTP Basic gated by
    /// magnatune.com, satisfied by the `Authorization` header from `basicAuthHeader()`.
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

    // MARK: HTTP Basic for media

    /// The member-only files under `/music` are HTTP Basic gated (the server sends a real
    /// `WWW-Authenticate: Basic realm="Magnatune Membership"` challenge to non-browser
    /// clients). Auth is carried by an explicit `Authorization` header on every media
    /// request — `AVURLAssetHTTPHeaderFieldsKey` in `AudioPlayer.makeAsset`, and the
    /// `authHeader` parameter on `AudioCache` / `DownloadStore`.
    ///
    /// NOTE: registering a `URLCredential` in `URLCredentialStorage.shared` does NOT work
    /// here. CoreMedia loads media through its own out-of-process HTTP stack, which never
    /// consults the app's credential store — verified: the asset was created with
    /// `optionsDict (null)` and failed with `CoreMediaErrorDomain -16840 "HTTP 401"`.
    /// So `basicAuthHeader()` below is the single source of media auth; if it returns nil
    /// (e.g. the keychain is unreadable) every member stream 401s.

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

    /// Check a username/password against the same-origin SPA endpoint (navim4's
    /// `m3_check_member`), which POSTs `user=`/`pw=` and answers a tiny JSON verdict:
    /// `{"ok":true,"user":…}` ⇒ `.member`, `{"ok":false}` ⇒ `.notMember`, network failure
    /// ⇒ `.unreachable`. It is backed by the same membership check that gates `/music`,
    /// so the UI unlock always matches what can actually be streamed.
    static func membershipStatus(username: String, password: String) async -> MembershipStatus {
        guard !username.isEmpty, !password.isEmpty,
              let url = URL(string: "https://\(URLBuilder.host)/membership/check.php")
        else { return .notMember }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = CharacterSet.alphanumerics
        form.insert(charactersIn: "-._~")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: form) ?? s }
        req.httpBody = Data("user=\(enc(username))&pw=\(enc(password))".utf8)
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .notMember }
            let body = String(decoding: data, as: UTF8.self).replacingOccurrences(of: " ", with: "")
            return body.contains("\"ok\":true") ? .member : .notMember
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

    /// In-memory copy of the password for this launch. The keychain is the source of truth
    /// across launches, but a keychain failure must not silently disable media auth: the
    /// member `/music` files are HTTP Basic gated, so a nil password means every member
    /// stream 401s and playback dies with no obvious cause. Holding the password we were
    /// just given keeps the signed-in session working even if the keychain write failed.
    private var cachedPassword: String?

    private func readPassword() -> String? {
        if let cachedPassword { return cachedPassword }
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let pw = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                print("[Credentials] keychain read failed: OSStatus \(status)")
            }
            return nil
        }
        cachedPassword = pw
        return pw
    }

    private func writePassword(_ password: String) {
        deletePassword()            // clears the cache too — so set it AFTER
        cachedPassword = password
        var q = baseQuery()
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess {
            print("[Credentials] keychain write failed: OSStatus \(status)")
        }
    }

    private func deletePassword() {
        cachedPassword = nil
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
