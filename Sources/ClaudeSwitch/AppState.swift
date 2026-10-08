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

    // Settings
    @Setting("autoSwitch") var autoSwitch = true { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    @Setting("defaultID") var defaultID: String? = nil { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    @Setting("switchAtFive") var switchAtFive = 90.0 { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    @Setting("switchAtWeek") var switchAtWeek = 98.0 { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    @Setting("returnHome") var returnHome = true { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    @Setting("returnMax") var returnMax = 5 { willSet { objectWillChange.send() } didSet { settingsChanged() } }
    /// Set when you leave the default account by hand: autopilot then waits for the
    /// default's current 5-hour window to reset instead of pulling you straight back.
    @Setting("leftHomeByHand") private var leftHomeByHand = false
    /// Set when you cancel a planned return: no trip home until you next touch it.
    @Setting("homeHeldUntil") private var homeHeldUntil = 0.0      // unix time
    private var awayHeldUntil = Date.distantPast
    // Schedule: working hours and which accounts take part
    @Setting("kickoffOn") var kickoffOn = false { willSet { objectWillChange.send() } }
    @Setting("workStart") var workStart = 540 { willSet { objectWillChange.send() } }          // minutes after midnight
    @Setting("workEnd") var workEnd = 1440 { willSet { objectWillChange.send() } }
    @Setting("kickoffJitterMax") var kickoffJitterMax = 10 { willSet { objectWillChange.send() } }
    @Setting("kickoffWeekdays") var kickoffWeekdays = true { willSet { objectWillChange.send() } }
    /// The hour your day turns over (the schedule runs from here to the same hour next day).
    @Setting("dayStartHour") var dayStartHour = 2 {
        willSet { objectWillChange.send() }
        didSet {
            // Keep working hours inside the new day.
            let lo = dayStartHour * 60, hi = lo + 1440
            func into(_ m: Int) -> Int { var m = m; while m < lo { m += 1440 }; while m > hi { m -= 1440 }; return m }
            workStart = into(workStart)
            workEnd = max(into(workEnd), workStart + 30)
        }
    }
    @Setting("scheduleOff") var scheduleOff: [String] = [] { willSet { objectWillChange.send() } }
    @Setting("kickoffLog") var kickoffLog: [String: String] = [:]

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

    /// Two made-up accounts mid-afternoon: Work near its 5-hour limit with a switch
    /// back planned, Personal live, a week of activity, the schedule on.
    private func loadDemo() {
        let now = Date()
        let work = Account(id: "demo-work", email: "you@company.com", label: "Work", plan: "Max 20x")
        let personal = Account(id: "demo-personal", email: "you@personal.dev", label: "Personal", plan: "Max 20x")
        accounts = [work, personal]
        let weekReset = Calendar.current.date(byAdding: .day, value: 5, to: Calendar.current.startOfDay(for: now))!.addingTimeInterval(2 * 3600)
        usage = [
            work.id: Usage(fiveHour: Window(percent: 93, resetsAt: now.addingTimeInterval(52 * 60)),
                           weekly: Window(percent: 38, resetsAt: weekReset), fetchedAt: now),
            personal.id: Usage(fiveHour: Window(percent: 18, resetsAt: now.addingTimeInterval(3 * 3600 + 41 * 60)),
                               weekly: Window(percent: 17, resetsAt: weekReset), fetchedAt: now),
        ]
        activeID = personal.id
        defaultID = work.id
        autoSwitch = true
        switchAtWeek = 95
        returnMax = 5
        kickoffOn = true
        workStart = 9 * 60
        workEnd = 23 * 60
        kickoffWeekdays = true
        notificationsOn = true
        plan = Plan(kind: .home, target: work.id, at: now.addingTimeInterval(55 * 60))
        // A week of readings: both plans climbing through working hours, ending on today's figures.
        let start = weekReset.addingTimeInterval(-7 * 86_400)
        var hours: [Date] = []
        var t = start
        while t < now { hours.append(t); t = t.addingTimeInterval(3600) }
        let busy = hours.filter { (9...22).contains(Calendar.current.component(.hour, from: $0)) }.count
        var done = 0
        for h in hours {
            if (9...22).contains(Calendar.current.component(.hour, from: h)) { done += 1 }
            let f = busy == 0 ? 1 : Double(done) / Double(busy)
            samples.append(Sample(t: h, five: [:], week: [work.id: 38 * f, personal.id: 17 * f]))
        }
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
        if id != defaultID, activeID == defaultID { leftHomeByHand = true }
        if id == defaultID { leftHomeByHand = false; homeHeldUntil = 0 }
        awayHeldUntil = .distantPast
        plan = nil
        enqueue { await self.doSwitch(id) }
    }

    /// Cancels just this move. A cancelled return skips the default's next window,
    /// then auto-switch carries on as normal; a cancelled move away waits 15 minutes.
    func cancelPlan() {
        guard let p = plan else { return }
        if p.kind == .home { homeHeldUntil = p.at.addingTimeInterval(5 * 3600).timeIntervalSince1970 }
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
        await checkKickoffs()
    }

    private func record() {
        var five: [String: Double] = [:], week: [String: Double] = [:]
        for (id, u) in usage where accounts.contains(where: { $0.id == id }) {
            five[id] = u.fiveHour?.percent
            week[id] = u.weekly?.percent
        }
        guard !week.isEmpty else { return }
        if let d = try? JSONEncoder().encode(usage) { try? d.write(to: usageURL, options: .atomic) }
        let s = Sample(t: Date(), five: five, week: week)
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

    /// An account inside a window (the live one, or one a kick-off started) can take a
    /// one-token reply without starting anything new, and the reply's headers carry the
    /// same 5-hour and weekly figures. At most every 5 minutes.
    private func probeIfLive(_ acct: Account) async {
        let now = Date()
        let inWindow = acct.id == activeID || (usage[acct.id]?.fiveHour?.resetsAt.map { $0 > now } ?? false)
        guard inWindow, (usage[acct.id]?.fetchedAt ?? .distantPast).timeIntervalSince(now) < -240,
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

    /// Under both limits. The live account needs a reading from the last 10 minutes.
    /// An idle account barely moves, so an older reading will do: up to 6 hours if its
    /// 5-hour window has since ended (it's back to 0%), 30 minutes if one is running.
    func healthy(_ id: String) -> Bool {
        guard let u = usage[id] else { return false }
        let now = Date()
        let ended = u.fiveHour?.resetsAt.map { $0 <= now } ?? true
        let five = ended ? 0 : (u.fiveHour?.percent ?? 0)
        let maxAge: TimeInterval = id == activeID ? 600 : ended ? 6 * 3600 : 1800
        guard now.timeIntervalSince(u.fetchedAt) <= maxAge else { return false }
        return five < switchAtFive && (u.weekly?.percent ?? 0) < switchAtWeek
    }

    /// When the windows holding this account over its limits reset.
    private func clearsAt(_ id: String) -> Date? {
        guard let u = usage[id] else { return nil }
        var dates: [Date] = []
        if let w = u.fiveHour, w.percent >= switchAtFive, let r = w.resetsAt { dates.append(r) }
        if let w = u.weekly, w.percent >= switchAtWeek, let r = w.resetsAt { dates.append(r) }
        return dates.max()
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
        var base = clearsAt(home) ?? now
        if leftHomeByHand, healthy(home) {
            // You chose to leave a default that had room: wait out its current window,
            // and if it had no window running, stay put until you switch back yourself.
            guard let r = usage[home]?.fiveHour?.resetsAt, r > now else { return }
            base = max(base, r)
        }
        if base < now { base = now }
        // With the schedule on, go back when it starts the default's next window,
        // so both pages show the same time.
        if kickoffOn, let start = self.plan(for: now).first(where: { $0.account.id == home && $0.start >= base.addingTimeInterval(-60) })?.start {
            plan = Plan(kind: .home, target: home, at: start)
        } else {
            plan = Plan(kind: .home, target: home, at: base.addingTimeInterval(humanDelay(minutes: 1...max(1, returnMax))))
        }
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
