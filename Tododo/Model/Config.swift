import Foundation

/// Where to sync. Set in Settings, or shipped in a local (git-ignored) Secrets.plist.
struct Config: Equatable {
    var url: URL
    var token: String

    private static let urlKey = "serverURL"
    private static let tokenKey = "appToken"

    static var current: Config? {
        let d = UserDefaults.standard
        if let c = make(d.string(forKey: urlKey), d.string(forKey: tokenKey)) { return c }
        if let path = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: path) {
            return make(dict["ServerURL"] as? String, dict["AppToken"] as? String)
        }
        return nil
    }

    static func save(url: String, token: String) {
        let d = UserDefaults.standard
        d.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
        d.set(token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: tokenKey)
    }

    private static func make(_ url: String?, _ token: String?) -> Config? {
        guard let s = url?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              let u = URL(string: s), u.scheme != nil,
              let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
        else { return nil }
        return Config(url: u, token: t)
    }
}
