import Foundation

/// Claude Code token-usage stats, scanned straight from the local session logs
/// (`~/.claude/projects/**/*.jsonl`) — no network, no auth, works offline.
///
/// Each JSONL line Claude Code writes carries a `message.usage` block; we sum the
/// *meaningful* tokens (input + output + cache-creation, excluding cache *reads*,
/// which re-bill the same context every turn and balloon totals into the billions),
/// price them per model, and bucket by day. Ported from the `claude-usage` app's
/// `UsageStore`/`Pricing`, trimmed to just the Claude side this gizmo displays.
struct ClaudeUsage: Equatable {
    struct Day: Equatable {
        let date: String      // YYYY-MM-DD
        let weekday: String   // single letter: M T W T F S S
        let tokens: Int
        let cost: Double
    }

    var todayTokens = 0
    var todayCost = 0.0
    var monthTokens = 0
    var monthCost = 0.0
    var weekTokens = 0        // sum of last7
    var weekCost = 0.0
    var last7: [Day] = []     // oldest → newest, length 7
    var topModel: String?     // prettified, e.g. "OPUS 4.6" (today's costliest)
    var generatedAt = Date.distantPast

    static let empty = ClaudeUsage()

    /// True once we've found any real usage to show (else the gizmo shows a "sleeping" state).
    var hasData: Bool {
        todayTokens > 0 || weekTokens > 0 || monthTokens > 0 || last7.contains { $0.tokens > 0 }
    }

    /// The largest single-day token count across the week (for scaling the bar chart).
    var maxDayTokens: Int { max(1, last7.map(\.tokens).max() ?? 1) }
}

// MARK: - Scanner

enum ClaudeUsageScanner {
    /// Scan the local Claude Code logs and aggregate. Synchronous and file-bound — call it
    /// off the main thread. Returns `.empty` (with `generatedAt` stamped) if nothing is found.
    static func scan() -> ClaudeUsage {
        let records = scanRecords()
        return aggregate(records)
    }

    // MARK: Paths

    /// The real user home — robust even if the process home is redirected.
    private static var homeURL: URL {
        let path = NSHomeDirectoryForUser(NSUserName()) ?? ("/Users/" + NSUserName())
        return URL(fileURLWithPath: path)
    }
    private static var claudeDir: URL { homeURL.appendingPathComponent(".claude/projects") }

    /// Whether Claude Code appears to be installed (at least one project dir present).
    static func hasClaudeInstalled() -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: claudeDir.path)) ?? []
        return !entries.isEmpty
    }

    // MARK: Raw records

    private struct Record {
        let timestamp: Date
        let model: String
        let meaningfulTokens: Int
        let input: Int, output: Int, cacheRead: Int, cacheWrite: Int
    }

    private static func scanRecords() -> [Record] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: claudeDir.path) else { return [] }
        let cutoff = Date().addingTimeInterval(-35 * 86_400)   // a month-plus of history
        var out: [Record] = []

        guard let projects = try? fm.contentsOfDirectory(
            at: claudeDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        for project in projects {
            guard let files = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                if let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, mod < cutoff { continue }
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                    if let rec = parse(String(line)) { out.append(rec) }
                }
            }
        }
        return out
    }

    private static func parse(_ line: String) -> Record? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              let tsStr = obj["timestamp"] as? String,
              let date = parseISO8601(tsStr) else { return nil }

        let i  = (usage["input_tokens"] as? Int) ?? 0
        let o  = (usage["output_tokens"] as? Int) ?? 0
        let cr = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let cw = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        if i == 0, o == 0, cr == 0, cw == 0 { return nil }   // empty ping

        return Record(timestamp: date, model: model, meaningfulTokens: i + o + cw,
                      input: i, output: o, cacheRead: cr, cacheWrite: cw)
    }

    // MARK: Aggregation

    private static func aggregate(_ records: [Record]) -> ClaudeUsage {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = .current

        var u = ClaudeUsage()
        var dayBuckets: [String: (cost: Double, tokens: Int)] = [:]
        var todayModelCost: [String: Double] = [:]

        for r in records {
            let cost = Pricing.cost(model: r.model, input: r.input, output: r.output,
                                    cacheRead: r.cacheRead, cacheWrite: r.cacheWrite)
            let key = dayFmt.string(from: r.timestamp)
            let prev = dayBuckets[key] ?? (0, 0)
            dayBuckets[key] = (prev.cost + cost, prev.tokens + r.meaningfulTokens)

            if calendar.isDate(r.timestamp, inSameDayAs: today) {
                u.todayTokens += r.meaningfulTokens
                u.todayCost += cost
                todayModelCost[r.model, default: 0] += cost
            }
            if r.timestamp >= monthStart {
                u.monthTokens += r.meaningfulTokens
                u.monthCost += cost
            }
        }

        let weekdayFmt = DateFormatter()
        weekdayFmt.locale = Locale(identifier: "en_US_POSIX")
        weekdayFmt.dateFormat = "EEEEE"   // single-letter weekday

        for offset in (0..<7).reversed() {
            let d = calendar.date(byAdding: .day, value: -offset, to: today)!
            let key = dayFmt.string(from: d)
            let bucket = dayBuckets[key] ?? (0, 0)
            u.last7.append(.init(date: key, weekday: weekdayFmt.string(from: d).uppercased(),
                                 tokens: bucket.tokens, cost: bucket.cost))
            u.weekTokens += bucket.tokens
            u.weekCost += bucket.cost
        }

        u.topModel = todayModelCost.max { $0.value < $1.value }.map { Pricing.pretty($0.key) }
        u.generatedAt = Date()
        return u
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}

// MARK: - Pricing (Claude families, USD per million tokens; approximate, early 2026)

enum Pricing {
    struct Price { let input, output, cacheRead, cacheWrite: Double }

    /// Matched case-insensitively as `contains` against the model id, most-specific first.
    static let table: [(pattern: String, price: Price)] = [
        ("opus-4-8", Price(input: 15.0, output: 75.0, cacheRead: 1.50, cacheWrite: 18.75)),
        ("opus-4-7", Price(input: 15.0, output: 75.0, cacheRead: 1.50, cacheWrite: 18.75)),
        ("opus-4-6", Price(input: 15.0, output: 75.0, cacheRead: 1.50, cacheWrite: 18.75)),
        ("opus",     Price(input: 15.0, output: 75.0, cacheRead: 1.50, cacheWrite: 18.75)),
        ("sonnet-4-6", Price(input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75)),
        ("sonnet-4-5", Price(input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75)),
        ("sonnet",   Price(input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75)),
        ("haiku-4-5", Price(input: 0.80, output: 4.0, cacheRead: 0.08, cacheWrite: 1.0)),
        ("haiku",    Price(input: 0.80, output: 4.0, cacheRead: 0.08, cacheWrite: 1.0)),
    ]

    static func price(for model: String) -> Price? {
        let lower = model.lowercased()
        return table.first { lower.contains($0.pattern) }?.price
    }

    static func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        guard let p = price(for: model) else { return 0 }
        return (Double(input) * p.input + Double(output) * p.output
              + Double(cacheRead) * p.cacheRead + Double(cacheWrite) * p.cacheWrite) / 1_000_000.0
    }

    /// "claude-opus-4-6-20250101" → "OPUS 4.6". Best-effort; unknown ids pass through trimmed.
    static func pretty(_ model: String) -> String {
        let lower = model.lowercased()
        let family: String
        if lower.contains("opus") { family = "OPUS" }
        else if lower.contains("sonnet") { family = "SONNET" }
        else if lower.contains("haiku") { family = "HAIKU" }
        else { return model.uppercased() }

        // Pull the first "major-minor" version pair after the family name.
        if let range = lower.range(of: #"(\d+)-(\d+)"#, options: .regularExpression) {
            let ver = lower[range].replacingOccurrences(of: "-", with: ".")
            return "\(family) \(ver)"
        }
        return family
    }
}
