import Foundation

/// Where to sync. Set once with a connection link (`tododo://setup?url=…&token=…`),
/// or shipped in a local, git-ignored Secrets.plist.
struct Config: Equatable {
    var url: URL
    var token: String

    private static let urlKey = "serverURL"
    private static let tokenKey = "appToken"

    static var current: Config? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let c = make(env["TODODO_URL"], env["TODODO_TOKEN"]) { return c }
        #endif
        let d = UserDefaults.standard
        if let c = make(d.string(forKey: urlKey), d.string(forKey: tokenKey)) { return c }
        if let path = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: path) {
            return make(dict["ServerURL"] as? String, dict["AppToken"] as? String)
        }
        return nil
    }

    /// Accepts a connection link or code. Returns false if it is not one.
    @discardableResult
    static func applySetup(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), parts.scheme == "tododo", parts.host == "setup" else { return false }
        let items = parts.queryItems ?? []
        let url = items.first { $0.name == "url" }?.value
        let token = items.first { $0.name == "token" }?.value
        guard let c = make(url, token) else { return false }
        let d = UserDefaults.standard
        d.set(c.url.absoluteString, forKey: urlKey)
        d.set(c.token, forKey: tokenKey)
        return true
    }

    static func disconnect() {
        UserDefaults.standard.removeObject(forKey: urlKey)
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    private static func make(_ url: String?, _ token: String?) -> Config? {
        guard let s = url?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              let u = URL(string: s), u.scheme != nil, u.host != nil,
              let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
        else { return nil }
        return Config(url: u, token: t)
    }
}
