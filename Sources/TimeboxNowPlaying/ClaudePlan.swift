import Foundation
import Security

/// Claude Code plan-limit status: the 5-hour session window and the weekly window, each with a
/// used-percent and reset time, plus the plan tier.
///
/// Primary source is Anthropic's own OAuth usage endpoint (`/api/oauth/usage`) — the exact data
/// behind Claude Code's `/usage` command — authenticated with Claude Code's *own* locally-stored
/// OAuth token, so this app is self-contained: if you use Claude Code, the limits just show up.
/// Falls back to the companion `claude-usage` app's cache, then to nothing (graph still works).
struct ClaudePlan: Equatable {
    var planTier: String?          // e.g. "Max", "Pro"
    var sessionPercent: Double?    // 5-hour window, 0…100
    var sessionResetsAt: Date?
    var weeklyPercent: Double?     // weekly (all models), 0…100
    var weeklyResetsAt: Date?
    var lastUpdated: Date?

    static let empty = ClaudePlan()
    var hasData: Bool { sessionPercent != nil || weeklyPercent != nil }

    /// "Max (5x)" → "MAX 5X"; "max" → "MAX".
    var tierShort: String? {
        guard let t = planTier?.uppercased()
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }
}

enum ClaudePlanReader {
    /// The Anthropic OAuth usage endpoint rate-limits aggressively; only call it on this cadence.
    static let minRefreshInterval: TimeInterval = 240

    /// Fetch live plan limits. Returns nil only if no source is available (so callers keep the
    /// last good value rather than clobbering it with empties on a transient failure).
    static func fetch() async -> ClaudePlan? {
        if let creds = loadCredentials(),
           let plan = try? await fetchUsage(token: creds.token, tier: creds.tier) {
            return plan
        }
        return companionCache()
    }

    // MARK: - Anthropic OAuth usage endpoint

    private static func fetchUsage(token: String, tier: String?) async throws -> ClaudePlan {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.0.0", forHTTPHeaderField: "User-Agent")   // required, else 429
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw URLError(.badServerResponse) }

        func section(_ key: String) -> (Double?, Date?) {
            guard let d = json[key] as? [String: Any] else { return (nil, nil) }
            return (num(d["utilization"]), (d["resets_at"] as? String).flatMap(parseISO))
        }
        var p = ClaudePlan()
        (p.sessionPercent, p.sessionResetsAt) = section("five_hour")
        (p.weeklyPercent, p.weeklyResetsAt) = section("seven_day")
        p.planTier = tier
        p.lastUpdated = Date()
        return p
    }

    // MARK: - Claude Code's OAuth token (env → file → Keychain)

    private static func loadCredentials() -> (token: String, tier: String?)? {
        if let t = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !t.isEmpty {
            return (t, nil)
        }
        let home = NSHomeDirectoryForUser(NSUserName()) ?? ("/Users/" + NSUserName())
        let fileURL = URL(fileURLWithPath: home).appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: fileURL), let c = parseCredentials(data) { return c }
        // macOS stores them in the Keychain; reading another app's item prompts once (Always Allow).
        if let data = keychainCredentials(), let c = parseCredentials(data) { return c }
        return nil
    }

    private static func keychainCredentials() -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// `{ "claudeAiOauth": { "accessToken", "expiresAt"(ms), "subscriptionType" } }`.
    private static func parseCredentials(_ data: Data) -> (token: String, tier: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let exp = num(oauth["expiresAt"]), exp > 0,
           exp / 1000 < Date().timeIntervalSince1970 { return nil }   // expired → let a fallback answer
        let tier = (oauth["subscriptionType"] as? String).map { $0.capitalized }
        return (token, tier)
    }

    // MARK: - Fallback: companion claude-usage app cache

    private static func companionCache() -> ClaudePlan? {
        let home = NSHomeDirectoryForUser(NSUserName()) ?? ("/Users/" + NSUserName())
        let url = URL(fileURLWithPath: home).appendingPathComponent(
            "Library/Containers/com.marcovhv.claudeusage.widget/Data/Library/Application Support/claude.plan.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        func section(_ key: String) -> (Double?, Date?) {
            guard let d = json[key] as? [String: Any] else { return (nil, nil) }
            return (num(d["usedPercent"]), (d["resetsAt"] as? String).flatMap(parseISO))
        }
        var p = ClaudePlan()
        p.planTier = json["planTier"] as? String
        (p.sessionPercent, p.sessionResetsAt) = section("currentSession")
        (p.weeklyPercent, p.weeklyResetsAt) = section("weeklyAllModels")
        p.lastUpdated = (json["lastUpdated"] as? String).flatMap(parseISO)
        return p.hasData ? p : nil
    }

    /// Diagnostic (DUMP_PLAN=1): reports which source answers and what it returned.
    static func debugDump() async -> String {
        var out: [String] = []
        if let creds = loadCredentials() {
            out.append("token: FOUND (tier=\(creds.tier ?? "nil"))")
            do {
                let p = try await fetchUsage(token: creds.token, tier: creds.tier)
                out.append("OAuth /api/oauth/usage OK → session=\(p.sessionPercent ?? -1)% (reset \(resetsIn(p.sessionResetsAt))), weekly=\(p.weeklyPercent ?? -1)% (reset \(resetsIn(p.weeklyResetsAt)))")
            } catch { out.append("OAuth fetch FAILED: \(error)") }
        } else {
            out.append("token: NOT found (env/file/keychain all empty)")
        }
        if let c = companionCache() {
            out.append("companion cache present → session=\(c.sessionPercent ?? -1)% weekly=\(c.weeklyPercent ?? -1)%")
        } else { out.append("companion cache: none") }
        return out.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func num(_ any: Any?) -> Double? { (any as? Double) ?? (any as? Int).map(Double.init) }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime]
        if let d = g.date(from: s) { return d }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {   // strip µs the formatter rejects
            var t = s; t.removeSubrange(r); return g.date(from: t)
        }
        return nil
    }
}

/// A short reset countdown: "3H 10M", "2D 8H", "45M", "NOW".
func resetsIn(_ date: Date?) -> String {
    guard let date else { return "—" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "NOW" }
    let d = secs / 86_400, h = (secs % 86_400) / 3600, m = (secs % 3600) / 60
    if d >= 1 { return "\(d)D \(h)H" }
    if h >= 1 { return "\(h)H \(m)M" }
    return "\(m)M"
}
