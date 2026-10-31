import AppKit
import CryptoKit
import Foundation
import ServiceManagement
import UserNotifications

struct Account: Codable, Identifiable, Equatable {
    var id: String          // Anthropic account uuid
    var email: String
    var label: String
    var plan: String
}

/// Runs the browser sign-in for a second account in a throwaway config dir, so
/// the account Claude Code is using right now is never touched.
final class LoginSession: @unchecked Sendable {
    let dir: URL
    private let process = Process()
    private let input = Pipe()

    init(dir: URL) { self.dir = dir }

    var keychainService: String {
        let digest = SHA256.hash(data: Data(dir.path.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    func run(claude: String, onURL: @escaping @Sendable (URL) -> Void) -> Int32 {
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["auth", "login", "--claudeai"]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = dir.path
        env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = input
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            if let r = s.range(of: #"https://\S+"#, options: .regularExpression), let u = URL(string: String(s[r])) { onURL(u) }
        }
        do { try process.run() } catch { return -1 }
        let deadline = Date().addingTimeInterval(600)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        if process.isRunning { process.terminate() }
        pipe.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }

    /// For when the browser shows a code instead of finishing by itself.
    func submit(code: String) {
        input.fileHandleForWriting.write(Data((code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
    }

    func cancel() { if process.isRunning { process.terminate() } }
}

/// What auto-switch intends to do next, shown in the panel so it never surprises.
struct Plan: Equatable {
    enum Kind { case away, home }
    var kind: Kind
    var target: String
    var at: Date
}

/// Where settings live. Demo renders swap in a throwaway store.
nonisolated(unsafe) var settingsStore = UserDefaults.standard

/// A UserDefaults-backed setting.
@propertyWrapper
struct Setting<T> {
    let key: String
    let fallback: T
    init(wrappedValue: T, _ key: String) { self.key = key; self.fallback = wrappedValue }
    var wrappedValue: T {
        get { settingsStore.object(forKey: key) as? T ?? fallback }
        set {
            if let opt = newValue as? OptionalProtocol, opt.isNil { settingsStore.removeObject(forKey: key) }
            else { settingsStore.set(newValue, forKey: key) }
        }
    }
}

protocol OptionalProtocol { var isNil: Bool { get } }
extension Optional: OptionalProtocol { var isNil: Bool { self == nil } }

@MainActor
final class AppState: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var activeID: String?
    @Published var usage: [String: Usage] = [:]
    @Published var errors: [String: String] = [:]
    @Published var status: String? { didSet { clearStatusLater() } }
    @Published var refreshing = false
    @Published var login: LoginSession?
    @Published var loginURL: URL?
    @Published var plan: Plan?
    /// Cursor and Codex accounts shown under the Claude plans, as many of each as you like.
    @Published var providers: [ProviderAccount] = []
    /// The tool being signed in to in the browser right now.
    @Published var providerSignIn: ProviderKind?
    private var providerSignInTask: Task<Void, Never>?
    @Published var providerUsage: [String: ProviderUsage] = [:]
    @Published var providerErrors: [String: String] = [:]
    private var providerNext: [String: Date] = [:]

    // Settings
    @Setting("autoSwitch") var autoSwitch = true { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    @Setting("defaultID") var defaultID: String? = nil { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    @Setting("switchAtWeek") var switchAtWeek = 98.0 { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    @Setting("returnHome") var returnHome = true { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    @Setting("returnMax") var returnMax = 5 { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    /// Set when you leave the default account by hand while it still had room:
    /// autopilot then leaves you be until you go back yourself.
    @Setting("leftHomeByHand") private var leftHomeByHand = false
    /// Set when you cancel a planned return: no trip home until then.
    @Setting("homeHeldUntil") private var homeHeldUntil = 0.0      // unix time
    private var awayHeldUntil = Date.distantPast

    @Published var activity = Activity()
    @Published var tab: Tab = .accounts
    @Setting("lastActiveID") private var lastActiveID: String? = nil
    private var retryAt: [String: Date] = [:]          // per account, after a 429
    let offline: Bool
    /// Made-up accounts and figures, for screenshots. Never touches real data.
    let demo: Bool
    @Published var samples: [Sample] = []
    private let history = History(dir: AppState.support)
    private let scanner = ActivityScanner(dir: AppState.support)
    private var lastScan = Date.distantPast

    @Published var openAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            do { openAtLogin ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { status = "Couldn't change Open at login" }
        }
    }

    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSwitch")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private var indexURL: URL { Self.support.appendingPathComponent("accounts.json") }
    private var usageURL: URL { Self.support.appendingPathComponent("usage.json") }
    private var providersURL: URL { Self.support.appendingPathComponent("providers.json") }
    private var owner: [String: String] = [:]          // access token -> account id
    private var queue: Task<Void, Never> = Task {}
    private var timer: Timer?
    private var nextFetch: [String: Date] = [:]        // per account: when usage is next due
    private var backoff: [String: TimeInterval] = [:]  // per account: current 429 back-off
    private var lastProbe: [String: Date] = [:]
    private var switching = false
    @Published var avatarVersion = 0
    private var avatarCache: [String: NSImage] = [:]
    @Setting("notificationsOn") var notificationsOn = true {
        willSet { objectWillChange.send() }
        didSet { if notificationsOn { Notifier.shared.ask() } }
    }
    private var statusClear: Task<Void, Never>?

    var active: Account? { accounts.first { $0.id == activeID } }
    func account(_ id: String?) -> Account? { accounts.first { $0.id == id } }

    /// `offline` (for --snapshot) shows the last saved state and never calls Anthropic.
    init(offline: Bool = false, demo: Bool = false) {
        self.offline = offline || demo
        self.demo = demo
        if demo {
            settingsStore = UserDefaults(suiteName: "ClaudeSwitchDemo")!
            settingsStore.removePersistentDomain(forName: "ClaudeSwitchDemo")
            loadDemo()
            return
        }
        if let d = try? Data(contentsOf: indexURL), let a = try? JSONDecoder().decode([Account].self, from: d) { accounts = a }
        if let d = try? Data(contentsOf: providersURL), let p = try? JSONDecoder().decode([ProviderAccount].self, from: d) { providers = p }
        samples = history.samples
        // Last known usage, so a relaunch (or a rate-limited fetch) still has numbers.
        if let d = try? Data(contentsOf: usageURL), let u = try? JSONDecoder().decode([String: Usage].self, from: d) { usage = u }
        activeID = lastActiveID
        scanActivity()
        guard !offline else { return }
        // First run: start with the Mac, and ask to show notifications.
        if !settingsStore.bool(forKey: "setUp") {
            settingsStore.set(true, forKey: "setUp")
            openAtLogin = true
        }
        if notificationsOn { Notifier.shared.ask() }
        // Every 20 s: act on anything due; each account's usage is fetched about every 5 minutes.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refresh()
    }

    /// Three made-up plans mid-afternoon: Work near its weekly limit, Personal live,
    /// Side project added later so its week resets on another day, a week of activity.
    private func loadDemo() {
        let now = Date()
        let work = Account(id: "demo-work", email: "you@company.com", label: "Work", plan: "Max 20x")
        let personal = Account(id: "demo-personal", email: "you@personal.dev", label: "Personal", plan: "Max 20x")
        let side = Account(id: "demo-side", email: "you@side.studio", label: "Side project", plan: "Max 5x")
        accounts = [work, personal, side]
        let weekReset = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now))!.addingTimeInterval(2 * 3600)
        let sideReset = now.addingTimeInterval(6 * 86_400 + 3 * 3600)
        let figures = [work.id: 91.0, personal.id: 44.0, side.id: 6.0]
        usage = [
            work.id: Usage(weekly: Window(percent: figures[work.id]!, resetsAt: weekReset), fetchedAt: now),
            personal.id: Usage(weekly: Window(percent: figures[personal.id]!, resetsAt: weekReset), fetchedAt: now),
            side.id: Usage(weekly: Window(percent: figures[side.id]!, resetsAt: sideReset), fetchedAt: now),
        ]
        activeID = personal.id
        defaultID = work.id
        autoSwitch = true
        switchAtWeek = 95
        returnMax = 5
        notificationsOn = true
        providers = [ProviderAccount(id: "demo-cursor", kind: .cursor, email: "you@company.com", label: "Work", plan: "Pro"),
                     ProviderAccount(id: "demo-codex", kind: .codex, email: "you@personal.dev", label: "Personal", plan: "Plus")]
        providerUsage = [
            "demo-cursor": ProviderUsage(windows: [ProviderWindow(title: "Monthly", icon: "calendar",
                                                             window: Window(percent: 37, resetsAt: now.addingTimeInterval(19 * 86_400)), length: 30 * 86_400, note: nil)],
                                    plan: "Pro", fetchedAt: now),
            "demo-codex": ProviderUsage(windows: [ProviderWindow(title: "5-hour", icon: "clock", window: Window(percent: 22, resetsAt: now.addingTimeInterval(3 * 3600)), length: 5 * 3600, note: nil),
                                             ProviderWindow(title: "Weekly", icon: "calendar", window: Window(percent: 48, resetsAt: now.addingTimeInterval(4 * 86_400)), length: 7 * 86_400, note: nil)],
                                   plan: "Plus", fetchedAt: now),
        ]
        // Each plan's readings through working hours, from its own week's start to today's figure.
        for a in accounts {
            guard let reset = usage[a.id]?.weekly?.resetsAt, let target = figures[a.id] else { continue }
            var hours: [Date] = []
            var t = reset.addingTimeInterval(-7 * 86_400)
            while t < now { hours.append(t); t = t.addingTimeInterval(3600) }
            let busy = max(1, hours.filter { (9...22).contains(Calendar.current.component(.hour, from: $0)) }.count)
            var done = 0
            for h in hours {
                if (9...22).contains(Calendar.current.component(.hour, from: h)) { done += 1 }
                samples.append(Sample(t: h, week: [a.id: target * Double(done) / Double(busy)]))
            }
        }
        samples.sort { $0.t < $1.t }
        // Activity: Mon–Fri working hours, busiest early afternoon.
        var a = Activity(loaded: true)
        var c = Calendar(identifier: .iso8601); c.timeZone = .current
        let monday = c.date(from: c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        for d in 0..<5 {
            for h in 8..<24 {
                let at = monday.addingTimeInterval(Double(d * 86_400 + h * 3600))
                guard at < now else { continue }
                let peak = exp(-pow(Double(h) - 14.5, 2) / 18)
                let dollars = (6 + 38 * peak) * (0.45 + rnd())
                let key = Int(at.timeIntervalSince1970) / 3600 * 3600
                a.cost[key] = dollars
                a.tokens[key] = dollars * 3_100_000
            }
        }
        activity = a
    }

    /// Opening the panel refreshes anything more than two minutes old.
    func refreshIfStale() {
        if usage.values.contains(where: { $0.fetchedAt.timeIntervalSinceNow < -120 }) { refresh() }
    }

    // MARK: - Public actions (serialised so a switch never races a refresh)

    /// `force` (the refresh button) fetches everything not backing off from a 429.
    func refresh(force: Bool = true) {
        guard !offline else { return }
        enqueue { await self.doRefresh(force: force) }
    }

    func switchTo(_ id: String) {
        if id != defaultID, activeID == defaultID, defaultID.map(healthy) == true { leftHomeByHand = true }
        if id == defaultID { leftHomeByHand = false; homeHeldUntil = 0 }
        awayHeldUntil = .distantPast
        plan = nil
        enqueue { await self.doSwitch(id) }
    }

    /// Cancels just this move. A cancelled return waits for the default's weekly reset
    /// (or a day), then auto-switch carries on as normal; a cancelled move away waits 15 minutes.
    func cancelPlan() {
        guard let p = plan else { return }
        if p.kind == .home { homeHeldUntil = (usage[p.target]?.weekly?.resetsAt ?? p.at.addingTimeInterval(86_400)).timeIntervalSince1970 }
        else { awayHeldUntil = Date().addingTimeInterval(15 * 60) }
        log("cancelled \(p.kind == .home ? "return" : "switch") to \(account(p.target)?.label ?? "?")")
        plan = nil
    }

    func makeDefault(_ id: String?) {
        defaultID = id
        homeHeldUntil = 0
        leftHomeByHand = false
    }

    func rename(_ id: String, to label: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let t = label.trimmingCharacters(in: .whitespaces)
        accounts[i].label = t.isEmpty ? accounts[i].email : t
        save()
    }

    func remove(_ id: String) {
        guard id != activeID else { return }
        Stash.delete(id)
        accounts.removeAll { $0.id == id }
        usage[id] = nil
        if defaultID == id { defaultID = nil }
        save()
    }

    func addAccount() {
        guard login == nil else { return }
        guard let claude = Self.findClaude() else {
            status = "Install Claude Code first"
            return
        }
        let dir = Self.support.appendingPathComponent("login-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = LoginSession(dir: dir)
        login = session
        loginURL = nil
        let before = Keychain.claudeServices()
        Task.detached {
            let code = session.run(claude: claude) { url in Task { @MainActor in self.loginURL = url } }
            await self.finishLogin(session, exitCode: code, servicesBefore: before)
        }
    }

    func cancelLogin() {
        login?.cancel()
    }

    /// Signs a Cursor or Codex account in through the browser. Signing in to one
    /// that's already here, or to `replacing` (a row that lost its login), updates it.
    func signInProvider(_ kind: ProviderKind, replacing: String? = nil) {
        guard providerSignIn == nil, login == nil else { return }
        providerSignIn = kind
        providerSignInTask = Task {
            defer { providerSignIn = nil; providerSignInTask = nil }
            do {
                let l = try await Providers.signIn(kind) { url in NSWorkspace.shared.open(url) }
                NSApp.activate(ignoringOtherApps: true)
                addProvider(kind, l, replacing: replacing)
            } catch is CancellationError {
            } catch {
                status = "Couldn't sign in to \(kind.name): \(error.localizedDescription)"
            }
        }
    }

    func cancelProviderSignIn() {
        providerSignInTask?.cancel()
    }

    private func addProvider(_ kind: ProviderKind, _ l: ProviderLogin, replacing: String?) {
        let key = "\(l.email ?? ""):\(l.accountID ?? "")"
        let id = kind.rawValue + "-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10)
        let email = l.email ?? ""
        Providers.save(l, for: id)
        let old = providers.first { $0.id == id } ?? replacing.flatMap { r in providers.first { $0.id == r } }
        // A name you gave it survives signing in again.
        let named = old.map { $0.label != $0.email && $0.label != kind.name } ?? false
        let p = ProviderAccount(id: id, kind: kind, email: email,
                                label: named ? old!.label : (l.name ?? (email.isEmpty ? kind.name : email)),
                                plan: l.plan.map(Providers.capitalised) ?? old?.plan ?? "")
        if let old, let i = providers.firstIndex(where: { $0.id == old.id }) {
            if old.id != id { forgetProvider(old.id) }
            providers[i] = p
        } else {
            providers.append(p)
        }
        saveProviders()
        status = "Added \(p.label)"
        providerErrors[id] = nil
        providerNext[id] = nil
        Task { await refreshProviders(force: true) }
    }

    func renameProvider(_ id: String, to label: String) {
        guard let i = providers.firstIndex(where: { $0.id == id }) else { return }
        let t = label.trimmingCharacters(in: .whitespaces)
        providers[i].label = t.isEmpty ? (providers[i].email.isEmpty ? providers[i].kind.name : providers[i].email) : t
        saveProviders()
    }

    func removeProvider(_ id: String) {
        forgetProvider(id)
        providers.removeAll { $0.id == id }
        saveProviders()
    }

    /// Drops a provider's login, picture and readings.
    private func forgetProvider(_ id: String) {
        Keychain.delete(Providers.service, account: id)
        try? FileManager.default.removeItem(at: avatarDir.appendingPathComponent("\(id).png"))
        avatarCache[id] = nil
        providerUsage[id] = nil
        providerErrors[id] = nil
    }

    /// Each provider about every 5 minutes; `force` (the refresh button) fetches all.
    func refreshProviders(force: Bool) async {
        guard !offline else { return }
        let now = Date()
        for p in providers where force || (providerNext[p.id] ?? .distantPast) <= now {
            providerNext[p.id] = now.addingTimeInterval(.random(in: 270...330))
            do {
                let u = try await Providers.usage(p)
                providerUsage[p.id] = u
                providerErrors[p.id] = nil
                if let plan = u.plan, let i = providers.firstIndex(where: { $0.id == p.id }), providers[i].plan != plan {
                    providers[i].plan = plan
                    saveProviders()
                }
            } catch {
                providerErrors[p.id] = error.localizedDescription
            }
        }
    }

    private func saveProviders() {
        if let d = try? JSONEncoder().encode(providers) { try? d.write(to: providersURL, options: .atomic) }
    }

    // MARK: - Work

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let prev = queue
        queue = Task { await prev.value; await work() }
    }

    private func tick() {
        enqueue { await self.doRefresh(force: false, quiet: true) }
        if Date().timeIntervalSince(lastScan) >= 600 { scanActivity() }
    }

    func scanActivity() {
        guard !demo else { return }
        lastScan = Date()
        let scanner = scanner
        Task.detached(priority: .utility) {
            let activity = scanner.scan()
            await MainActor.run { self.activity = activity }
        }
    }

    private func settingsChanged() {
        guard !offline else { return }
        plan = nil
        enqueue { await self.autopilot() }
    }

    private func clearStatusLater() {
        statusClear?.cancel()
        guard status != nil else { return }
        statusClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.status = nil }
        }
    }

    private func doRefresh(force: Bool, quiet: Bool = false) async {
        let now = Date()
        let due = accounts.filter { force || (nextFetch[$0.id] ?? .distantPast) <= now }
        if !quiet {
            refreshing = true
        }
        defer {
            if !quiet {
                // Let the spinner turn at least once so a quick refresh still reads as one.
                let left = 0.7 - Date().timeIntervalSince(now)
                if left > 0 { Task { try? await Task.sleep(for: .seconds(left)); self.refreshing = false } } else { refreshing = false }
            }
        }
        if !due.isEmpty || force { await syncLive() }
        for acct in due { await fetchUsage(acct) }
        if !due.isEmpty { record() }
        await autopilot()
        await refreshProviders(force: force)
    }

    private func record() {
        var week: [String: Double] = [:]
        for (id, u) in usage where accounts.contains(where: { $0.id == id }) { week[id] = u.weekly?.percent }
        guard !week.isEmpty else { return }
        if let d = try? JSONEncoder().encode(usage) { try? d.write(to: usageURL, options: .atomic) }
        let s = Sample(t: Date(), week: week)
        history.append(s)
        samples = history.samples
    }

    func fetchUsage(_ acct: Account) async {
        let now = Date()
        if let wait = retryAt[acct.id], wait > now {
            await probeIfLive(acct)
            return
        }
        do {
            usage[acct.id] = try await API.usage(try await token(for: acct))
            errors[acct.id] = nil
            backoff[acct.id] = nil
            nextFetch[acct.id] = now.addingTimeInterval(.random(in: 270...330))
        } catch APIError.http(429, _) {
            // Anthropic throttles the usage endpoint. Back off (5, 10, 20, 30 min) and,
            // for the live account, read its limits off a one-token reply instead.
            let wait = min((backoff[acct.id] ?? 150) * 2, 1800)
            log("usage throttled for \(acct.label), retrying in \(Int(wait / 60)) min")
            backoff[acct.id] = wait
            retryAt[acct.id] = now.addingTimeInterval(wait)
            nextFetch[acct.id] = retryAt[acct.id]
            await probeIfLive(acct)
        } catch APIError.expired {
            // The live login is mid-refresh in Claude Code; the next tick picks it up.
        } catch {
            errors[acct.id] = error.localizedDescription
        }
    }

    /// The live account is in use anyway, so a one-token reply costs it nothing that
    /// matters, and the reply's headers carry the weekly figure. At most every 5 minutes.
    private func probeIfLive(_ acct: Account) async {
        let now = Date()
        guard acct.id == activeID, (usage[acct.id]?.fetchedAt ?? .distantPast).timeIntervalSince(now) < -240,
              (lastProbe[acct.id] ?? .distantPast).timeIntervalSince(now) < -280 else { return }
        lastProbe[acct.id] = now
        if let u = try? await API.probe(try await token(for: acct)) { usage[acct.id] = u; errors[acct.id] = nil }
    }

    // MARK: - Event log

    /// events.log in Application Support: every switch, outside change, kick-off and throttle.
    func log(_ msg: String) {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let line = Data("\(f.string(from: Date()))  \(msg)\n".utf8)
        let url = Self.support.appendingPathComponent("events.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    // MARK: - Avatars

    private var avatarDir: URL {
        let d = Self.support.appendingPathComponent("avatars")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func avatar(_ id: String) -> NSImage? {
        if demo { return Self.demoAvatar(id) }
        if let img = avatarCache[id] { return img }
        let img = NSImage(contentsOf: avatarDir.appendingPathComponent("\(id).png"))
        avatarCache[id] = img
        return img
    }

    /// Made-up pictures for the demo accounts: a soft gradient and an initial.
    static func demoAvatar(_ id: String) -> NSImage? {
        let spec: (String, NSColor, NSColor)
        switch id {
        case "demo-work": spec = ("W", NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.55, green: 0.33, blue: 0.93, alpha: 1))
        case "demo-personal": spec = ("P", NSColor(srgbRed: 0.98, green: 0.55, blue: 0.33, alpha: 1), NSColor(srgbRed: 0.93, green: 0.33, blue: 0.47, alpha: 1))
        default: return nil
        }
        return NSImage(size: NSSize(width: 160, height: 160), flipped: false) { r in
            NSGradient(starting: spec.1, ending: spec.2)!.draw(in: NSBezierPath(rect: r), angle: -45)
            let s = NSAttributedString(string: spec.0, attributes: [.font: NSFont.systemFont(ofSize: 76, weight: .semibold), .foregroundColor: NSColor.white])
            s.draw(at: NSPoint(x: r.midX - s.size().width / 2, y: r.midY - s.size().height / 2))
            return true
        }
    }

    /// Saves a square 160px copy of any image file as the account's picture.
    func setAvatar(_ id: String, from url: URL) {
        guard let src = NSImage(contentsOf: url) else { return }
        let side: CGFloat = 160
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        let s = src.size, scale = max(side / s.width, side / s.height)
        let w = s.width * scale, h = s.height * scale
        src.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: avatarDir.appendingPathComponent("\(id).png"))
        avatarCache[id] = nil
        avatarVersion += 1
    }

    func pickAvatar(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.message = "Choose a picture for this account"
        if p.runModal() == .OK, let url = p.url { setAvatar(id, from: url) }
    }

    // MARK: - Autopilot

    /// Under its weekly limit. The live account needs a reading from the last 10
    /// minutes; an idle one barely moves, so one from the last 2 hours will do (or
    /// any reading, once its week has reset back to 0%).
    func healthy(_ id: String) -> Bool {
        guard let u = usage[id] else { return false }
        let now = Date()
        if let r = u.weekly?.resetsAt, r <= now { return true }
        let maxAge: TimeInterval = id == activeID ? 600 : 2 * 3600
        guard now.timeIntervalSince(u.fetchedAt) <= maxAge else { return false }
        return (u.weekly?.percent ?? 0) < switchAtWeek
    }

    /// When the weekly window holding this account over its limit resets.
    private func clearsAt(_ id: String) -> Date? {
        guard let w = usage[id]?.weekly, w.percent >= switchAtWeek else { return nil }
        return w.resetsAt
    }

    private func humanDelay(minutes: ClosedRange<Int>) -> TimeInterval {
        let lo = Double(min(minutes.lowerBound, minutes.upperBound)) * 60
        let hi = Double(max(minutes.lowerBound, minutes.upperBound)) * 60
        return lo == hi ? lo : Double.random(in: lo...hi)
    }

    private func autopilot() async {
        guard !offline else { return }
        guard autoSwitch, let current = activeID, let u = usage[current], u.fetchedAt.timeIntervalSinceNow > -600 else { plan = nil; return }
        let now = Date()

        if let p = plan, now >= p.at {
            plan = nil
            if p.kind == .home, let acct = account(p.target) { await fetchUsage(acct) }
            let stillNeeded = p.kind == .away ? !healthy(current) : true
            if stillNeeded, p.target != activeID, healthy(p.target) {
                await doSwitch(p.target, auto: p.kind)
                if p.kind == .home { leftHomeByHand = false }
                return
            }
        }

        // Over a limit: move to the freshest account after a short, uneven pause.
        if !healthy(current) {
            if plan?.kind != .away, now >= awayHeldUntil {
                let best = accounts.filter { $0.id != current && healthy($0.id) }
                    .min { (usage[$0.id]?.pressure ?? 100) < (usage[$1.id]?.pressure ?? 100) }
                plan = best.map { Plan(kind: .away, target: $0.id, at: now.addingTimeInterval(.random(in: 20...90))) }
            }
            return
        }
        if plan?.kind == .away { plan = nil }

        // Away from the default: go back a few random minutes after it frees up.
        guard returnHome, now.timeIntervalSince1970 >= homeHeldUntil, let home = defaultID, home != current, account(home) != nil else {
            if plan?.kind == .home { plan = nil }
            return
        }
        guard plan?.kind != .home else { return }
        // You chose to leave a default that had room: stay put until you go back yourself.
        if leftHomeByHand, healthy(home) { return }
        let base = max(clearsAt(home) ?? now, now)
        plan = Plan(kind: .home, target: home, at: base.addingTimeInterval(humanDelay(minutes: 1...max(1, returnMax))))
    }

    /// Works out whose login is live and keeps our copy of it current: Claude Code
    /// rotates tokens when it refreshes, and a stale copy would be useless later.
    private func syncLive() async {
        guard let live = Live.read(), let oauth = live["claudeAiOauth"] as? JSON,
              let at = oauth["accessToken"] as? String, !at.isEmpty else { activeID = nil; return }
        var id = owner[at]
        if id == nil {
            let rt = oauth["refreshToken"] as? String
            id = accounts.first { acct in
                guard let saved = Stash.read(acct.id)?["claudeAiOauth"] as? JSON else { return false }
                return saved["accessToken"] as? String == at || (rt != nil && saved["refreshToken"] as? String == rt)
            }?.id
        }
        var profile: JSON?
        if id == nil {
            // A token we haven't seen: ask Anthropic who it belongs to.
            guard let p = try? await API.profile(at), let uuid = (p["account"] as? JSON)?["uuid"] as? String else { return }
            id = uuid
            profile = p
        }
        guard let id else { return }
        owner[at] = id
        if let before = activeID, before != id, !switching {
            // Someone else changed the login: Claude Code (/login), another tool, or a write-back.
            let from = account(before)?.label ?? "another account", to = account(id)?.label ?? "a new account"
            log("live login changed outside Claude Switch: \(from) -> \(to)")
            notify("Claude Code is now on \(to)", body: "The login changed outside Claude Switch (it was \(from)).")
        }
        activeID = id
        lastActiveID = id

        var saved = Stash.read(id) ?? [:]
        if (saved["claudeAiOauth"] as? JSON)?["accessToken"] as? String != at || saved["oauthAccount"] == nil {
            saved["claudeAiOauth"] = oauth
            if saved["oauthAccount"] == nil {
                let config = ClaudeConfig.oauthAccount()
                if config?["accountUuid"] as? String == id {
                    saved["oauthAccount"] = config
                } else {
                    if profile == nil { profile = try? await API.profile(at) }
                    if let profile { saved["oauthAccount"] = API.oauthAccount(fromProfile: profile) }
                }
            }
            Stash.write(id, saved)
        }
        if !accounts.contains(where: { $0.id == id }) { remember(id: id, oauth: oauth, oauthAccount: saved["oauthAccount"] as? JSON) }
    }

    func token(for acct: Account) async throws -> String {
        if acct.id == activeID {
            guard let oauth = Live.read()?["claudeAiOauth"] as? JSON, let at = oauth["accessToken"] as? String else { throw APIError.expired }
            // Never refresh the live login ourselves: Claude Code owns it.
            if API.expiresSoon(oauth, within: 0) { throw APIError.expired }
            return at
        }
        guard var saved = Stash.read(acct.id), var oauth = saved["claudeAiOauth"] as? JSON else { throw APIError.bad("Not saved. Add it again.") }
        if API.expiresSoon(oauth) {
            oauth = try await API.refresh(oauth)
            saved["claudeAiOauth"] = oauth
            Stash.write(acct.id, saved)
        }
        guard let at = oauth["accessToken"] as? String else { throw APIError.bad("No token") }
        return at
    }

    private func doSwitch(_ id: String, auto: Plan.Kind? = nil) async {
        guard !offline else { return }
        switching = true
        defer { switching = false }
        await syncLive()
        guard id != activeID, let acct = accounts.first(where: { $0.id == id }),
              var saved = Stash.read(id), var oauth = saved["claudeAiOauth"] as? JSON else { return }
        if API.expiresSoon(oauth) {
            do {
                oauth = try await API.refresh(oauth)
                saved["claudeAiOauth"] = oauth
                Stash.write(id, saved)
            } catch {
                status = "\(acct.label) is signed out"
                errors[id] = error.localizedDescription
                return
            }
        }
        var live = Live.read() ?? [:]          // keeps MCP logins stored alongside
        live["claudeAiOauth"] = oauth
        guard Live.write(live) else {
            status = "Couldn't switch: keychain refused"
            return
        }
        if let oa = saved["oauthAccount"] as? JSON { try? ClaudeConfig.setOAuthAccount(oa) }
        if let at = oauth["accessToken"] as? String { owner[at] = id }
        activeID = id
        lastActiveID = id
        log("switched to \(acct.label) (\(auto == .away ? "auto: limit" : auto == .home ? "auto: back to default" : "by hand"))")
        switch auto {
        case .away?: notify("Switched to \(acct.label)", body: "The other account hit its limit. Running chats move over within 30 seconds.")
        case .home?: notify("Back on \(acct.label)", body: "Its limit has reset.")
        case nil: status = "Now on \(acct.label)"
        }
        nextFetch[id] = nil
        await fetchUsage(acct)
    }

    nonisolated private func finishLogin(_ session: LoginSession, exitCode: Int32, servicesBefore: Set<String>) async {
        var service = session.keychainService
        if Keychain.read(service) == nil, let fresh = Keychain.claudeServices().subtracting(servicesBefore).first { service = fresh }
        let creds = Keychain.read(service).flatMap(parseJSON)
        let config = ClaudeConfig.oauthAccount(at: session.dir.appendingPathComponent(".claude.json"))
        Keychain.delete(service)
        try? FileManager.default.removeItem(at: session.dir)
        await MainActor.run {
            self.login = nil
            self.loginURL = nil
        }
        guard let oauth = creds?["claudeAiOauth"] as? JSON, let at = oauth["accessToken"] as? String else {
            await MainActor.run { self.status = exitCode == 0 ? "Sign-in didn't save a login" : nil }
            return
        }
        let profile = try? await API.profile(at)
        var oauthAccount = config
        if oauthAccount == nil, let profile { oauthAccount = API.oauthAccount(fromProfile: profile) }
        guard let id = (oauthAccount?["accountUuid"] as? String) ?? ((profile?["account"] as? JSON)?["uuid"] as? String) else {
            await MainActor.run { self.status = "Couldn't tell which account that was" }
            return
        }
        let finalAccount = oauthAccount
        await MainActor.run { self.adopt(id: id, oauth: oauth, oauthAccount: finalAccount) }
    }

    private func adopt(id: String, oauth: JSON, oauthAccount: JSON?) {
        let email = oauthAccount?["emailAddress"] as? String ?? "that account"
        if id == activeID {
            status = "That's the account you're on"
            return
        }
        var saved: JSON = ["claudeAiOauth": oauth]
        saved["oauthAccount"] = oauthAccount
        Stash.write(id, saved)
        if accounts.contains(where: { $0.id == id }) {
            status = "Signed \(email) back in"
        } else {
            remember(id: id, oauth: oauth, oauthAccount: oauthAccount)
            status = "Added \(email)"; notify("Account added", body: email)
        }
        refresh()
    }

    private func remember(id: String, oauth: JSON, oauthAccount: JSON?) {
        let email = oauthAccount?["emailAddress"] as? String ?? "Account \(accounts.count + 1)"
        accounts.append(Account(id: id, email: email, label: email, plan: Self.planName(oauth)))
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(accounts) { try? d.write(to: indexURL, options: .atomic) }
    }

    func notify(_ title: String, body: String) {
        guard notificationsOn else { return }
        Notifier.shared.send(title, body)
    }

    static func planName(_ oauth: JSON) -> String {
        let tier = oauth["rateLimitTier"] as? String ?? ""
        if tier.hasSuffix("max_20x") { return "Max 20x" }
        if tier.hasSuffix("max_5x") { return "Max 5x" }
        switch oauth["subscriptionType"] as? String {
        case "max": return "Max"
        case "pro": return "Pro"
        case let s?: return s.capitalized
        default: return ""
        }
    }

    static func findClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let r = shell("/bin/zsh", ["-lc", "command -v claude"])
        let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
