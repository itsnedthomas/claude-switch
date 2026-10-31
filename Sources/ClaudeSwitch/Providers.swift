import Foundation

/// Other AI tools whose plan limits we show next to Claude's.
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case cursor, codex

    var id: String { rawValue }
    var name: String {
        switch self {
        case .cursor: return "Grok Bot"   // its X Subscription allowance is shared by Cursor, Grok and Grok Bot
        case .codex: return "ChatGPT"
        }
    }
    var brand: Brand { self == .cursor ? .grokBot : .codex }
}

/// A Cursor or Codex account signed in through Claude Switch. Its login lives in
/// the Keychain under `id`.
struct ProviderAccount: Codable, Identifiable, Equatable {
    var id: String
    var kind: ProviderKind
    var email: String
    var label: String
    var plan: String

    init(id: String, kind: ProviderKind, email: String, label: String, plan: String) {
        (self.id, self.kind, self.email, self.label, self.plan) = (id, kind, email, label, plan)
    }

    /// Entries from before sign-in had no id or name: they keep the kind as id
    /// and, having no login, ask to be signed in again.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ProviderKind.self, forKey: .kind)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        plan = try c.decodeIfPresent(String.self, forKey: .plan) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? kind.rawValue
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? (email.isEmpty ? kind.name : email)
    }
}

/// One limit a provider reports, shown like Claude's weekly bar.
struct ProviderWindow: Codable, Equatable {
    var title: String
    var icon: String
    var window: Window
    /// Window length in seconds, for pace projections.
    var length: TimeInterval
    /// Extra line under the bar, e.g. "$4.20 on-demand".
    var note: String?
}

struct ProviderUsage: Codable, Equatable {
    var windows: [ProviderWindow]
    var plan: String?
    var fetchedAt: Date
}

/// Usage for the Cursor and Codex logins Claude Switch signed in itself. Each
/// login is refreshed here when it's about to expire or the server turns it down.
enum Providers {
    static let service = "ClaudeSwitch-provider"
    static let signedOut = "Signed out. Sign in again"

    static func login(_ id: String) -> ProviderLogin? {
        Keychain.read(service, account: id).flatMap { try? JSONDecoder().decode(ProviderLogin.self, from: Data($0.utf8)) }
    }

    static func save(_ login: ProviderLogin, for id: String) {
        guard let d = try? JSONEncoder().encode(login) else { return }
        Keychain.write(service, account: id, value: String(decoding: d, as: UTF8.self))
    }

    static func signIn(_ kind: ProviderKind, open: @escaping (URL) -> Void) async throws -> ProviderLogin {
        switch kind {
        case .cursor: return try await CursorAuth.signIn(open: open)
        case .codex: return try await CodexAuth.signIn(open: open)
        }
    }

    static func usage(_ p: ProviderAccount) async throws -> ProviderUsage {
        guard var l = login(p.id) else { throw APIError.bad(signedOut) }
        if let exp = l.expires, exp < Date().addingTimeInterval(300) { l = try await renew(l, p) }
        do {
            return try await read(p.kind, l)
        } catch APIError.bad(let m) where m == signedOut {
            return try await read(p.kind, renew(l, p))
        }
    }

    private static func renew(_ l: ProviderLogin, _ p: ProviderAccount) async throws -> ProviderLogin {
        guard l.refresh != nil else { throw APIError.bad(signedOut) }
        let n: ProviderLogin
        do {
            n = try await p.kind == .cursor ? CursorAuth.refresh(l) : CodexAuth.refresh(l)
        } catch let e where e is CancellationError || e is URLError {
            throw e
        } catch {
            throw APIError.bad(signedOut)
        }
        save(n, for: p.id)
        return n
    }

    private static func read(_ kind: ProviderKind, _ l: ProviderLogin) async throws -> ProviderUsage {
        switch kind {
        case .cursor: return try await Cursor.usage(l)
        case .codex: return try await Codex.usage(l)
        }
    }

    // MARK: Cursor

    enum Cursor {
        static let url = URL(string: "https://cursor.com/api/usage-summary")!

        static let poolURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!

        static func usage(_ l: ProviderLogin) async throws -> ProviderUsage {
            async let shared = pool(l)
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue(CursorAuth.cookie(l), forHTTPHeaderField: "Cookie")
            req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let j = try await fetch(req, signedOut: signedOut)

            let start = (j["billingCycleStart"] as? String).flatMap(parseISO)
            let end = (j["billingCycleEnd"] as? String).flatMap(parseISO)
            let ind = j["individualUsage"] as? JSON ?? [:]
            let plan = ind["plan"] as? JSON ?? [:]
            var pct = num(plan["totalPercentUsed"])
            if pct == nil, let used = num(plan["used"]), let limit = num(plan["limit"]), limit > 0 {
                pct = used / limit * 100
            }
            var note: String?
            if let od = ind["onDemand"] as? JSON, od["enabled"] as? Bool == true,
               let used = num(od["used"]), used > 0 {
                note = String(format: "$%.2f on-demand", used / 100)
            }
            let length = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : 30 * 86400
            let w = ProviderWindow(title: "Monthly", icon: "calendar",
                                   window: Window(percent: min(max(pct ?? 0, 0), 100), resetsAt: end),
                                   length: length, note: note)
            // An X Subscription's weekly pool is the limit that bites, so it replaces the monthly bar.
            let pool = await shared
            return ProviderUsage(windows: [pool?.window ?? w],
                                 plan: pool?.plan ?? (j["membershipType"] as? String).map(capitalised), fetchedAt: Date())
        }

        /// The weekly allowance an X Subscription shares between Cursor, Grok and Grok
        /// Bot, when the account has one. Best effort: without it the monthly bar shows.
        static func pool(_ l: ProviderLogin) async -> (window: ProviderWindow, plan: String?)? {
            var req = URLRequest(url: poolURL, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.httpBody = Data("{}".utf8)
            for (k, v) in ["Content-Type": "application/json", "Authorization": "Bearer \(l.access)",
                           "Connect-Protocol-Version": "1", "x-cursor-client-type": "sand",
                           "x-cursor-client-version": "0.1.0", "x-sand-box-namespace": "prod", "x-ghost-mode": "true"] {
                req.setValue(v, forHTTPHeaderField: k)
            }
            guard let j = try? await fetch(req, signedOut: signedOut),
                  j["hasNonZeroIncludedLimit"] as? Bool == true, let pct = num(j["usagePercent"]) else { return nil }
            let w = ProviderWindow(title: "Weekly", icon: "calendar",
                                   window: Window(percent: min(max(pct, 0), 100), resetsAt: (j["nextResetTimestampUtc"] as? String).flatMap(parseISO)),
                                   length: 7 * 86400, note: nil)
            return (w, (j["cursorPlanName"] as? String).map(capitalised))
        }
    }

    // MARK: Codex

    enum Codex {
        static let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

        static func usage(_ l: ProviderLogin) async throws -> ProviderUsage {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("Bearer \(l.access)", forHTTPHeaderField: "Authorization")
            if let id = l.accountID { req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
            req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let j = try await fetch(req, signedOut: signedOut)

            let rl = j["rate_limit"] as? JSON ?? [:]
            let windows = ["primary_window", "secondary_window"].compactMap { window(rl[$0]) }
            let plan = (j["plan_type"] as? String).map(capitalised) ?? l.plan
            return ProviderUsage(windows: windows, plan: plan, fetchedAt: Date())
        }

        static func window(_ any: Any?) -> ProviderWindow? {
            guard let w = any as? JSON, let pct = num(w["used_percent"]) else { return nil }
            let secs = num(w["limit_window_seconds"]) ?? 0
            var reset: Date?
            if let at = num(w["reset_at"]) { reset = Date(timeIntervalSince1970: at) }
            else if let after = num(w["reset_after_seconds"]) { reset = Date().addingTimeInterval(after) }
            let (title, icon) = label(secs)
            return ProviderWindow(title: title, icon: icon, window: Window(percent: min(max(pct, 0), 100), resetsAt: reset),
                                  length: secs, note: nil)
        }

        /// 18000 s is "5-hour", 604800 s is "Weekly", anything else by hours or days.
        static func label(_ secs: Double) -> (String, String) {
            switch Int(secs) {
            case 18000: return ("5-hour", "clock")
            case 604800: return ("Weekly", "calendar")
            case let s where s > 0 && s % 86400 == 0: return ("\(s / 86400)-day", "calendar")
            case let s where s > 0: return ("\(max(1, Int((Double(s) / 3600).rounded())))-hour", "clock")
            default: return ("Limit", "gauge")
            }
        }
    }

    // MARK: Shared

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    static func fetch(_ req: URLRequest, signedOut: String) async throws -> JSON {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw APIError.bad(signedOut) }
        guard code == 200 else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { throw APIError.bad("Unreadable reply") }
        return j
    }

    /// The claims in a JWT, unverified.
    static func jwtPayload(_ token: String) -> JSON? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let d = Data(base64Encoded: s) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? JSON
    }

    static func num(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    static func capitalised(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "_" || $0 == " " }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

extension ProviderUsage {
    /// The weekly window, when the tool has one.
    var weekly: ProviderWindow? { windows.first { abs($0.length - 7 * 86_400) < 3600 } }
}
