import AppKit
import Charts
import SwiftUI

enum Tab: String, CaseIterable {
    case accounts = "Accounts", usage = "Usage", settings = "Settings"

    var icon: String {
        switch self {
        case .accounts: return "person.2"
        case .usage: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}

func tokens(_ n: Double) -> String {
    if n >= 1_000_000_000 { return String(format: "%.1fB", n / 1_000_000_000) }
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    return n >= 1000 ? "\(Int(n / 1000))k" : "\(Int(n))"
}

func dollars(_ n: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.currencySymbol = "$"
    f.maximumFractionDigits = n >= 100 ? 0 : 2
    return f.string(from: NSNumber(value: n)) ?? "$\(Int(n))"
}

func hhmm(_ minutes: Int) -> String {
    let m = ((minutes % 1440) + 1440) % 1440
    return String(format: "%02d:%02d", m / 60, m % 60)
}

/// Each account's colour in the usage chart, in list order.
func accountColor(_ index: Int) -> Color {
    [Theme.accent, Color(red: 0.56, green: 0.42, blue: 0.94), Color(red: 0.07, green: 0.65, blue: 0.58),
     Color(red: 0.91, green: 0.24, blue: 0.51)][index % 4]
}

func toneColor(_ t: Outlook.Tone) -> Color {
    switch t {
    case .fine: return Theme.accent
    case .close: return Theme.signal
    case .out: return Theme.danger
    }
}

/// Off for --snapshot renders, which can't wait for things to animate in.
nonisolated(unsafe) var animateIn = true

/// Set while rendering film frames (--film): the seconds since the current tab
/// appeared. Load-in animations read it through `appear` instead of animating.
nonisolated(unsafe) var filmTime: Double?

/// 0→1 for a load-in that starts after `delay` and lasts `duration`, eased out.
/// Live, it's just whether the view has appeared (SwiftUI animates the change).
func appear(_ shown: Bool, delay: Double = 0, duration: Double = 0.5) -> Double {
    guard let t = filmTime else { return shown ? 1 : 0 }
    let p = min(1, max(0, (t - delay) / duration))
    return 1 - pow(1 - p, 3)
}

/// The panel's content. The width never changes; the height follows the tab (the
/// menu bar window grows or shrinks with it). A new tab is revealed top to bottom.
struct PanelView: View {
    @EnvironmentObject var state: AppState
    var resetOnAppear = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Switcher(tab: $state.tab) { EmptyView() }
                RefreshButton(spinning: state.refreshing) { state.refresh() }
            }
            ZStack(alignment: .top) {
                Group {
                    switch state.tab {
                    case .accounts: AccountsTab()
                    case .usage: UsageTab()
                    case .settings: SettingsTab()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .id(state.tab)
                .modifier(Reveal(progress: filmTime == nil ? 1 : appear(true, duration: 0.35)))
                .transition(.asymmetric(
                    insertion: .modifier(active: Reveal(progress: 0), identity: Reveal(progress: 1))
                        .animation(.easeOut(duration: 0.24)),
                    removal: .identity))
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .top)
        .focusEffectDisabled()
    }
}

private struct PanelHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Hands back the NSWindow a view lives in.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { found(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { found(w) } }
    }
}

/// The menu bar window doesn't resize when its content does, so this eases its
/// height to each tab, keeping the top edge pinned under the menu bar.
struct FitsWindow: ViewModifier {
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in Color.clear.preference(key: PanelHeight.self, value: g.size.height) })
            .background(WindowReader { w in if window !== w { window = w } })
            .onPreferenceChange(PanelHeight.self) { h in resize(to: h) }
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private func resize(to h: CGFloat) {
        guard let w = window, h > 0 else { return }
        var f = w.frame
        let limit = (w.screen?.visibleFrame.height ?? 900) - 12
        let target = min(h, limit)
        guard abs(f.height - target) > 0.5 else { return }
        let top = f.maxY
        f.size.height = target
        f.origin.y = top - target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(f, display: true)
        }
    }
}

/// Fades content in from the top edge down.
struct Reveal: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(min(1, progress * 1.5))
            .mask(LinearGradient(stops: [.init(color: .black, location: progress * 1.5 - 0.5),
                                         .init(color: .clear, location: progress * 1.5)],
                                 startPoint: .top, endPoint: .bottom))
    }
}

/// The segmented switch, the full width of the cards: a sunken track, the
/// chosen tab raised, and an extra control (refresh) at the end of the track.
struct Switcher<Trailing: View>: View {
    @Binding var tab: Tab
    @ViewBuilder var trailing: Trailing
    @Namespace private var ns
    @State private var hovered: Tab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { withAnimation(.snappy(duration: 0.25)) { tab = t } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 10, weight: .medium))
                            .symbolEffect(.bounce, value: hovered == t)
                        Text(t.rawValue).font(.system(size: 12, weight: .medium))
                    }
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(tab == t || hovered == t ? Theme.ink : Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background {
                        if tab == t {
                            RoundedRectangle(cornerRadius: 6).fill(Theme.surface)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
                .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovered = h ? t : (hovered == t ? nil : hovered) } }
            }
            trailing
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sunken))
    }
}

/// A small floating card for hover details. Drawn over the layout, never in it.
struct HoverCard: View {
    let lines: [(String, Color)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l.0).foregroundStyle(l.1)
            }
        }
        .font(Theme.micro)
        .fixedSize()
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

// MARK: - Accounts

struct AccountsTab: View {
    @EnvironmentObject var state: AppState
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.accounts.isEmpty {
                Text("Sign in to Claude Code once and your account shows up here.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            } else {
                Box {
                    if !state.providers.isEmpty { CardHeader(brand: .claude, title: "Claude"); Hairline() }
                    ForEach(Array(state.accounts.enumerated()), id: \.1.id) { i, acct in
                        if i > 0 { Hairline() }
                        AccountRow(account: acct, ns: ns)
                    }
                }
                .animation(.snappy(duration: 0.4), value: state.activeID)
            }
            ForEach(ProviderKind.allCases) { k in
                let ps = state.providers.filter { $0.kind == k }
                if !ps.isEmpty { ProviderCard(kind: k, accounts: ps) }
            }
            Footer()
        }
    }
}

/// One fixed-height line under the accounts: Add account on the left, whatever
/// is planned or just happened on the right. Signing in takes over the line.
struct Footer: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            if state.login != nil {
                ProgressView().controlSize(.mini)
                Text("Sign in with your other account in the browser").foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                HoverLink(icon: "xmark", text: "Cancel", tone: .danger, rest: Theme.subtle) { state.cancelLogin() }
            } else if let k = state.providerSignIn {
                ProgressView().controlSize(.mini)
                Text("Sign in to \(k.name) in the browser").foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                HoverLink(icon: "xmark", text: "Cancel", tone: .danger, rest: Theme.subtle) { state.cancelProviderSignIn() }
            } else {
                AddAccountMenu()
                Spacer(minLength: 8)
                if let plan = state.plan, let target = state.account(plan.target) {
                    HoverLink(icon: plan.kind == .home ? "arrow.uturn.backward" : "arrow.right", hoverIcon: "xmark",
                              text: plan.kind == .home ? "Back to \(target.label) ~\(clock(plan.at))" : "To \(target.label) at \(clock(plan.at))",
                              tone: .danger) {
                        state.cancelPlan()
                    }
                    .help("Cancel this switch")
                } else if let status = state.status {
                    Text(status).foregroundStyle(Theme.subtle)
                }
            }
        }
        .font(Theme.micro)
        .lineLimit(1)
        .frame(height: 18)
        .padding(.horizontal, 2)
        .animation(.easeOut(duration: 0.2), value: state.plan)
        .animation(.easeOut(duration: 0.2), value: state.status)
        .animation(.easeOut(duration: 0.2), value: state.login != nil)
    }
}

/// An account's picture, or its initial. A set picture keeps a faint ring.
struct Avatar: View {
    @EnvironmentObject var state: AppState
    let id: String
    let label: String
    var size: CGFloat = 28

    init(id: String, label: String, size: CGFloat = 28) { (self.id, self.label, self.size) = (id, label, size) }
    init(account: Account, size: CGFloat = 28) { self.init(id: account.id, label: account.label, size: size) }

    var body: some View {
        let _ = state.avatarVersion
        Group {
            if let img = state.avatar(id) {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: size, height: size).background(.white).clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.line))
            } else {
                Circle().fill(Theme.accent.opacity(0.12))
                    .overlay(Text(label.prefix(1).uppercased())
                        .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(Theme.accent))
            }
        }
        .frame(width: size, height: size)
    }
}

struct AccountRow: View {
    @EnvironmentObject var state: AppState
    let account: Account
    var ns: Namespace.ID
    @State private var hovering = false

    var body: some View {
        let isActive = state.activeID == account.id
        let u = state.usage[account.id]
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Avatar(account: account)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if !account.plan.isEmpty {
                        Text(account.plan).font(Theme.micro).foregroundStyle(Theme.subtle)
                    }
                }
                Spacer()
                if isActive {
                    // The same chip glides up or down to whichever account is live.
                    Chip(text: "Active", tone: .success).matchedGeometryEffect(id: "active", in: ns)
                } else {
                    HoverButton(title: "Switch", icon: "arrow.left.arrow.right") { state.switchTo(account.id) }.transition(.opacity)
                }
            }
            UsageBlock(icon: "calendar", title: "Weekly", window: u?.weekly, length: 7 * 86_400, hovering: $hovering)
            if let e = state.errors[account.id] {
                Text(e).font(Theme.micro).foregroundStyle(Theme.warnInk).lineLimit(1)
            }
        }
        .padding(12)
        .zIndex(hovering ? 1 : 0)
    }
}

/// "Add account": a Claude account, or a Cursor or Codex one to track.
struct AddAccountMenu: View {
    @EnvironmentObject var state: AppState
    @State private var hover = false

    var body: some View {
        Menu {
            Button { state.addAccount() } label: { Label { Text("Claude account") } icon: { Image(nsImage: Brand.claude.image) } }
            Section("Track another tool") {
                ForEach(ProviderKind.allCases) { k in
                    Button { state.signInProvider(k) } label: { Label { Text("\(k.name) account") } icon: { Image(nsImage: k.brand.image) } }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 12)
                Text("Add account")
            }
            .foregroundStyle(hover ? Theme.accent : Theme.muted)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
    }
}

/// A card's title line, for when Claude shares the tab with other tools.
struct CardHeader: View {
    let brand: Brand
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            BrandMark(brand: brand, size: 13).frame(width: 14)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Every Cursor or every Codex account, in one card under the tool's logo.
struct ProviderCard: View {
    let kind: ProviderKind
    let accounts: [ProviderAccount]

    var body: some View {
        Box {
            CardHeader(brand: kind.brand, title: kind.name)
            ForEach(accounts) { p in
                Hairline()
                ProviderRow(provider: p)
            }
        }
    }
}

/// A Cursor or Codex account, laid out like a Claude one: picture, name, plan,
/// and one bar per limit it reports.
struct ProviderRow: View {
    @EnvironmentObject var state: AppState
    let provider: ProviderAccount
    @State private var hovering = false

    var body: some View {
        let u = state.providerUsage[provider.id]
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Avatar(id: provider.id, label: provider.label)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    let sub = [provider.label == provider.email ? "" : provider.email, provider.plan].filter { !$0.isEmpty }
                    if !sub.isEmpty { Text(sub.joined(separator: " · ")).font(Theme.micro).foregroundStyle(Theme.subtle).lineLimit(1) }
                }
                Spacer()
            }
            if let u, !u.windows.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(u.windows.enumerated()), id: \.offset) { _, w in
                        UsageBlock(icon: w.icon, title: w.title, window: w.window, length: w.length, hovering: $hovering)
                    }
                }
                let notes = u.windows.compactMap(\.note)
                if !notes.isEmpty { Text(notes.joined(separator: " · ")).font(Theme.micro).foregroundStyle(Theme.subtle).lineLimit(1) }
            } else if state.providerErrors[provider.id] == nil {
                Text(u == nil ? "Reading usage…" : "No limits reported").font(Theme.micro).foregroundStyle(Theme.subtle)
            }
            if let e = state.providerErrors[provider.id] {
                HStack(spacing: 6) {
                    Text(e).font(Theme.micro).foregroundStyle(Theme.warnInk).lineLimit(1)
                    Spacer(minLength: 4)
                    if e == Providers.signedOut {
                        HoverLink(icon: "arrow.up.right", text: "Sign in") { state.signInProvider(provider.kind, replacing: provider.id) }
                            .font(Theme.micro)
                    }
                }
            }
        }
        .padding(12)
        .zIndex(hovering ? 1 : 0)
    }
}

/// One limit: name and %, a bar, and when it resets. The bar is blue, orange if
/// it's on course to run close, red if it's on course to run out. Hover for the detail.
struct UsageBlock: View {
    let icon: String
    let title: String
    let window: Window?
    let length: TimeInterval
    @Binding var hovering: Bool
    @State private var hover = false
    @State private var shown = !animateIn

    var body: some View {
        let pct = window?.percent ?? 0
        let look = outlook(window, length: length)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.subtle)
                Text(title).font(Theme.micro).foregroundStyle(Theme.muted)
                Spacer(minLength: 4)
                Text(window == nil ? "–" : "\(Int((pct * (filmTime == nil ? 1 : appear(shown, delay: 0.15, duration: 0.7))).rounded()))%")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                    .contentTransition(.numericText(value: pct))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.lineSoft)
                    Capsule().fill(toneColor(look.tone))
                        .frame(width: max(pct > 0 ? 4 : 0, g.size.width * min(max(pct, 0), 100) / 100) * appear(shown, delay: 0.15, duration: 0.7))
                }
            }
            .frame(height: 4)
            Group {
                if let r = window?.resetsAt, r > Date() {
                    Text("Resets in \(span(r.timeIntervalSinceNow))")
                } else {
                    Text("Not started")
                }
            }
            .font(Theme.micro).foregroundStyle(Theme.subtle).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h; hovering = h } }
        .overlay(alignment: .topLeading) {
            if hover, let w = window {
                HoverCard(lines: detail(w, look)).alignmentGuide(.top) { $0[.bottom] + 6 }
            }
        }
        .animation(.easeOut(duration: 0.5), value: pct)
        .animation(.easeOut(duration: 0.3), value: look.tone)
        .onAppear { withAnimation(.easeOut(duration: 0.55).delay(0.05)) { shown = true } }
    }

    private func detail(_ w: Window, _ look: Outlook) -> [(String, Color)] {
        var lines: [(String, Color)] = [("\(Int(w.percent.rounded()))% used, \(Int(max(0, 100 - w.percent).rounded()))% left", Theme.ink)]
        if let r = w.resetsAt, r > Date() {
            lines.append(("Resets \(fullDate(r))", Theme.muted))
            if let out = look.runsOut {
                lines.append(("At this pace it runs out ~\(clock(out))", toneColor(look.tone)))
            } else if let at = look.atReset {
                lines.append(("At this pace ~\(Int(min(at, 100).rounded()))% by then", look.tone == .fine ? Theme.subtle : toneColor(look.tone)))
            }
        } else {
            lines.append(("Starts when it's next used", Theme.muted))
        }
        return lines
    }
}

// MARK: - Usage

struct UsageTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let f = WeekForecast.make(accounts: state.accounts.map { ($0.id, $0.label) }, usage: state.usage, samples: state.samples) {
                WeekCard(f: f, colors: Dictionary(uniqueKeysWithValues: state.accounts.enumerated().map { ($1.id, accountColor($0)) }))
            } else {
                Text(state.usage.isEmpty ? "Waiting for usage…" : "No plan has started its week yet. It starts when you next use it.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            }
            ActivityCard(activity: state.activity, accounts: state.accounts.count)
        }
    }
}

/// Every plan's week on one chart: each plan's line in its own colour from its own
/// week's start, dashed on to its own reset at its pace so far. The line under it
/// says whether, moving between plans, you'd run out before one resets.
struct WeekCard: View {
    let f: WeekForecast
    let colors: [String: Color]
    @State private var hoverDate: Date?
    @State private var shown = !animateIn

    private var single: Bool { f.plans.count == 1 && f.count == 1 }

    var body: some View {
        let over = f.current - f.shouldBe
        let firstOut = f.plans.filter { $0.runsOut != nil }.min { $0.runsOut! < $1.runsOut! }
        Box {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(f.current.rounded()))%").font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(f.count > 2 ? "of your \(f.count) plans this week" : f.count == 2 ? "of both plans this week" : "of your plan this week")
                        .font(Theme.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    if over > 0 {
                        Chip(text: "\(Int(over.rounded()))% over pace", tone: .warn)
                    } else {
                        Chip(text: "\(Int((-over).rounded()))% under pace", tone: .success)
                    }
                }
                chart
                    .frame(height: 120)
                    .padding(.top, 6)
                    .mask(alignment: .leading) {
                        GeometryReader { g in Rectangle().frame(width: g.size.width * appear(shown, delay: 0.15, duration: 0.9)) }
                    }
                if f.plans.count > 1 {
                    HStack(spacing: 10) {
                        ForEach(f.plans) { p in
                            HStack(spacing: 4) {
                                Circle().fill(colors[p.id] ?? Theme.accent).frame(width: 6, height: 6)
                                Text("\(p.label) \(Int(p.current.rounded()))%").foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .font(Theme.micro).lineLimit(1)
                }
                readout(firstOut: firstOut).font(Theme.micro).lineLimit(1)
            }
            .padding(12)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.7).delay(0.05)) { shown = true } }
    }

    @ViewBuilder private func readout(firstOut: WeekForecast.Plan?) -> some View {
        if let d = hoverDate {
            if single, let p = f.plans.first, let v = p.value(at: d) {
                let pace = min(100, d.timeIntervalSince(p.start) / WeekForecast.week * 100)
                Text("\(fullDate(d)) · \(d > Date() ? "on course for" : "used") \(Int(v.rounded()))% · even pace \(Int(pace.rounded()))%")
                    .foregroundStyle(Theme.ink)
            } else {
                let parts = f.plans.compactMap { p in p.value(at: d).map { "\(p.label) \(Int($0.rounded()))%" } }
                Text(([fullDate(d)] + parts).joined(separator: " · ")).foregroundStyle(Theme.ink)
            }
        } else if let out = f.poolRunsOut {
            let next = f.plans.map(\.reset).filter { $0 > out }.min() ?? f.end
            Text(single ? "At this pace you run out \(clock(out)), \(span(next.timeIntervalSince(out))) early."
                        : "At this pace every plan runs out \(clock(out)), \(span(next.timeIntervalSince(out))) before one resets.")
                .foregroundStyle(toneColor(.out))
        } else if let p = firstOut, let out = p.runsOut {
            Text(single ? "At this pace you run out \(clock(out)), \(span(p.reset.timeIntervalSince(out))) early."
                        : "\(p.label) runs out \(clock(out)) at this pace; the others have room.")
                .foregroundStyle(toneColor(single ? .out : .close))
        } else if single, let p = f.plans.first {
            Text("At this pace you finish the week on \(Int(p.atReset.rounded()))%.").foregroundStyle(Theme.muted)
        } else {
            Text("At this pace every plan finishes its week under its limit.").foregroundStyle(Theme.muted)
        }
    }

    private var chart: some View {
        let now = Date()
        return Chart {
            if f.sharedReset, let p = f.plans.first {
                LineMark(x: .value("t", p.start), y: .value("%", 0), series: .value("s", "pace"))
                    .foregroundStyle(Theme.subtle.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                LineMark(x: .value("t", p.reset), y: .value("%", 100), series: .value("s", "pace"))
                    .foregroundStyle(Theme.subtle.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(f.plans) { p in
                let color = colors[p.id] ?? Theme.accent
                let end: (Date, Double) = p.runsOut.map { ($0, 100) } ?? (p.reset, min(p.atReset, 100))
                ForEach(Array(p.actual.enumerated()), id: \.offset) { _, pt in
                    if f.plans.count == 1 {
                        AreaMark(x: .value("t", pt.0), y: .value("%", pt.1)).foregroundStyle(color.opacity(0.1))
                    }
                    LineMark(x: .value("t", pt.0), y: .value("%", pt.1), series: .value("s", p.id))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                }
                LineMark(x: .value("t", now), y: .value("%", p.current), series: .value("s", p.id + "-ahead"))
                    .foregroundStyle(color.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                LineMark(x: .value("t", end.0), y: .value("%", end.1), series: .value("s", p.id + "-ahead"))
                    .foregroundStyle(color.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                PointMark(x: .value("t", now), y: .value("%", p.current)).foregroundStyle(color).symbolSize(24)
                if let out = p.runsOut {
                    PointMark(x: .value("t", out), y: .value("%", 100)).foregroundStyle(Theme.danger).symbolSize(28)
                }
                if let d = hoverDate, let v = p.value(at: d) {
                    PointMark(x: .value("t", d), y: .value("%", v)).foregroundStyle(Theme.ink).symbolSize(22)
                }
            }
            if let d = hoverDate {
                RuleMark(x: .value("hover", d)).foregroundStyle(Theme.subtle.opacity(0.5))
            }
        }
        .chartXScale(domain: f.start...f.end)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                AxisGridLine().foregroundStyle(Theme.lineSoft)
                AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.system(size: 9)).foregroundStyle(Theme.subtle) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated)).font(.system(size: 9)).foregroundStyle(Theme.subtle)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let x = p.x - (proxy.plotFrame.map { g[$0].origin.x } ?? 0)
                            if let d: Date = proxy.value(atX: x) { hoverDate = min(max(d, f.start), f.end) }
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
    }
}

enum ActivityRange: String, CaseIterable { case week = "Week", day = "24 hours", today = "Today" }

/// Spend by hour from Claude Code's transcripts: a Mon–Fri heat map, or bars for
/// the last 24 hours or today. Hovering shows the hour; otherwise the total.
struct ActivityCard: View {
    let activity: Activity
    let accounts: Int
    @State private var range: ActivityRange = .week
    @State private var hovered: Int?
    @State private var shown = !animateIn

    private let cal = Calendar.current

    var body: some View {
        Box {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Activity").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Spacer()
                    MiniSwitch(selection: $range)
                }
                ZStack(alignment: .top) {
                    switch range {
                    case .week: heatmap.transition(.opacity)
                    case .day, .today: bars.transition(.opacity).id(range)
                    }
                }
                readout
            }
            .padding(12)
        }
        .animation(.snappy(duration: 0.25), value: range)
        .onAppear { withAnimation(.easeOut(duration: 0.4)) { shown = true } }
    }

    // Hours on screen, as unix hour starts.
    private var hours: [Int] {
        switch range {
        case .week: return weekDays.flatMap { d in (0..<24).map { hourKey(d, $0) } }
        case .day:
            let now = Int(Date().timeIntervalSince1970) / 3600 * 3600
            return (0..<24).reversed().map { now - $0 * 3600 }
        case .today: return (0..<24).map { hourKey(cal.startOfDay(for: Date()), $0) }
        }
    }

    /// Monday to Friday of this week, plus a weekend day if it had any activity.
    private var weekDays: [Date] {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        let monday = c.date(from: c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        return (0..<7).compactMap { i -> Date? in
            let d = c.date(byAdding: .day, value: i, to: monday)!
            if i >= 5 { return (0..<24).contains { activity.cost[hourKey(d, $0)] ?? 0 > 0 } ? d : nil }
            return d
        }
    }

    private func hourKey(_ day: Date, _ h: Int) -> Int {
        (Int(day.timeIntervalSince1970) + h * 3600) / 3600 * 3600
    }

    private var heatmap: some View {
        let costs = hours.compactMap { activity.cost[$0] }.filter { $0 > 0 }.sorted()
        let top = costs.isEmpty ? 1 : costs[min(costs.count - 1, Int(Double(costs.count) * 0.95))]
        let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(weekDays, id: \.self) { d in
                HStack(spacing: 3) {
                    Text(dayFmt.string(from: d)).font(.system(size: 9, weight: cal.isDateInToday(d) ? .semibold : .regular))
                        .foregroundStyle(cal.isDateInToday(d) ? Theme.ink : Theme.subtle)
                        .frame(width: 26, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let key = hourKey(d, h)
                        let v = activity.cost[key] ?? 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(v > 0 ? Theme.accent.opacity(0.15 + 0.85 * min(v / top, 1)) : Theme.lineSoft)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(hovered == key ? Theme.ink.opacity(0.7) : .clear, lineWidth: 1.2))
                            .frame(maxWidth: .infinity).frame(height: 12)
                            .opacity(appear(shown, delay: 0.15 + Double(h) * 0.025, duration: 0.3))
                            .animation(filmTime == nil ? .easeOut(duration: 0.3).delay(Double(h) * 0.012) : nil, value: shown)
                            .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) }
                    }
                }
            }
            HStack(spacing: 3) {
                Color.clear.frame(width: 26, height: 1)
                ForEach(0..<24, id: \.self) { h in
                    // Centred under its column.
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 10)
                        .overlay { if h % 6 == 0 { Text("\(h)").font(.system(size: 9)).foregroundStyle(Theme.subtle).fixedSize() } }
                }
            }
        }
    }

    private var bars: some View {
        Chart(hours, id: \.self) { h in
            BarMark(x: .value("Hour", Date(timeIntervalSince1970: Double(h)), unit: .hour),
                    y: .value("Spend", shown ? activity.cost[h] ?? 0 : 0))
                .foregroundStyle(hovered == nil || hovered == h ? Theme.accent : Theme.accent.opacity(0.35))
                .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour(), centered: true).font(.system(size: 9)).foregroundStyle(Theme.subtle)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Theme.lineSoft)
                AxisValueLabel { Text(dollars(v.as(Double.self) ?? 0)).font(.system(size: 9)).foregroundStyle(Theme.subtle) }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let x = p.x - (proxy.plotFrame.map { g[$0].origin.x } ?? 0)
                            if let d: Date = proxy.value(atX: x) { hovered = Int(d.timeIntervalSince1970) / 3600 * 3600 }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .frame(height: 112)
    }

    private var readout: some View {
        Group {
            if !activity.loaded {
                Text("Reading Claude Code's history…").foregroundStyle(Theme.subtle)
            } else if let h = hovered {
                let d = Date(timeIntervalSince1970: Double(h))
                let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:00"; return f }()
                Text("\(f.string(from: d)) · \(dollars(activity.cost[h] ?? 0)) (\(tokens(activity.tokens[h] ?? 0)) tokens)")
                    .foregroundStyle(Theme.ink)
            } else {
                let cost = hours.reduce(0) { $0 + (activity.cost[$1] ?? 0) }
                let toks = hours.reduce(0) { $0 + (activity.tokens[$1] ?? 0) }
                let when = range == .week ? "this week" : range == .day ? "in the last 24 hours" : "today"
                Text("\(dollars(cost)) at API prices (\(tokens(toks)) tokens) \(when)\(accounts > 2 ? ", all \(accounts) accounts" : accounts == 2 ? ", both accounts" : "").")
                    .foregroundStyle(Theme.subtle)
            }
        }
        .font(Theme.micro).lineLimit(1)
    }
}

/// A smaller version of the tab switch, for options inside a card.
struct MiniSwitch<T: RawRepresentable & CaseIterable & Hashable>: View where T.RawValue == String, T.AllCases: RandomAccessCollection {
    @Binding var selection: T
    @Namespace private var ns
    @State private var hovered: T?

    var body: some View {
        HStack(spacing: 1) {
            ForEach(T.allCases, id: \.self) { o in
                Button { withAnimation(.snappy(duration: 0.22)) { selection = o } } label: {
                    Text(o.rawValue).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selection == o || hovered == o ? Theme.ink : Theme.subtle)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background {
                            if selection == o {
                                RoundedRectangle(cornerRadius: 5).fill(Theme.surface)
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
                .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovered = h ? o : (hovered == o ? nil : hovered) } }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.sunken))
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: state.providers.isEmpty ? "Accounts" : "Claude accounts")
            Box {
                ForEach(Array(state.accounts.enumerated()), id: \.1.id) { i, a in
                    if i > 0 { Hairline() }
                    AccountSettingsRow(account: a)
                }
                Hairline()
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.subtle).frame(width: 16)
                    if state.login != nil {
                        Text("Sign in with your other account in the browser").font(Theme.caption).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer()
                        HoverButton(title: "Cancel", icon: "xmark", tone: .danger) { state.cancelLogin() }
                    } else {
                        Text("Add account").font(Theme.body).foregroundStyle(Theme.ink)
                        Spacer()
                        HoverButton(title: "Sign in", icon: "arrow.up.right") { state.addAccount() }
                    }
                }
                .padding(.horizontal, 12).frame(height: 38)
            }

            SectionTitle(text: "Auto-switch").padding(.top, 6)
            Box {
                Row(icon: "arrow.left.arrow.right", label: "Auto-switch") { OToggle(isOn: $state.autoSwitch) }
                Hairline()
                Row(icon: "house", label: "Default account") {
                    Menu {
                        Button("None") { state.makeDefault(nil) }
                        Divider()
                        ForEach(state.accounts) { a in Button(a.label) { state.makeDefault(a.id) } }
                    } label: {
                        Text(state.account(state.defaultID)?.label ?? "None").font(Theme.caption)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Hairline()
                Row(icon: "calendar", label: "Leave at weekly") {
                    Nudge(value: $state.switchAtWeek, step: 1, range: 50...100) { "\(Int($0))%" }
                }
                Hairline()
                Row(icon: "arrow.uturn.backward", label: "Return to default") { OToggle(isOn: $state.returnHome) }
                Hairline()
                Row(icon: "timer", label: "Return delay") {
                    Nudge(value: Binding(get: { Double(state.returnMax) }, set: { state.returnMax = Int($0) }),
                          step: 1, range: 1...30) { "up to \(Int($0)) min" }
                }
            }

            SectionTitle(text: "Other tools").padding(.top, 6)
            Box {
                ForEach(state.providers) { p in
                    ProfileSettingsRow(id: p.id, label: p.label, detail: [p.email, p.plan], badge: p.kind.brand,
                                       rename: { state.renameProvider(p.id, to: $0) }, remove: { state.removeProvider(p.id) })
                    Hairline()
                }
                ForEach(Array(ProviderKind.allCases.enumerated()), id: \.1) { i, k in
                    if i > 0 { Hairline() }
                    HStack(spacing: 10) {
                        BrandMark(brand: k.brand, size: 14).frame(width: 16)
                        if state.providerSignIn == k {
                            Text("Sign in to \(k.name) in the browser").font(Theme.caption).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer()
                            HoverButton(title: "Cancel", icon: "xmark", tone: .danger) { state.cancelProviderSignIn() }
                        } else {
                            Text("Add \(k.name) account").font(Theme.body).foregroundStyle(Theme.ink)
                            Spacer()
                            HoverButton(title: "Sign in", icon: "arrow.up.right") { state.signInProvider(k) }
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                }
            }

            SectionTitle(text: "General").padding(.top, 6)
            Box {
                Row(icon: "bell", label: "Notifications") { OToggle(isOn: $state.notificationsOn) }
                Hairline()
                Row(icon: "power", label: "Open at login") { OToggle(isOn: $state.openAtLogin) }
                Hairline()
                Row(icon: "xmark.circle", label: "Quit Claude Switch") {
                    HoverButton(title: "Quit", icon: "power", tone: .danger) { NSApp.terminate(nil) }
                }
            }
        }
    }
}

/// A Claude account's settings row.
struct AccountSettingsRow: View {
    @EnvironmentObject var state: AppState
    let account: Account

    var body: some View {
        ProfileSettingsRow(id: account.id, label: account.label, detail: [account.email, account.plan],
                           rename: { state.rename(account.id, to: $0) },
                           remove: state.activeID == account.id ? nil : { state.remove(account.id) })
    }
}

/// Picture (click or drop an image to change it), name (click to rename),
/// email and plan, and Remove when `remove` is given. `badge` marks the tool.
struct ProfileSettingsRow: View {
    @EnvironmentObject var state: AppState
    let id: String
    let label: String
    let detail: [String]
    var badge: Brand?
    let rename: (String) -> Void
    let remove: (() -> Void)?
    @State private var editing = false
    @State private var draft = ""
    @State private var hoverPic = false

    var body: some View {
        HStack(spacing: 10) {
            Button { state.pickAvatar(id) } label: {
                Avatar(id: id, label: label, size: 30)
                    .overlay {
                        if hoverPic {
                            Circle().fill(.black.opacity(0.35))
                                .overlay(Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let badge {
                            BrandMark(brand: badge, size: 9).padding(2.5)
                                .background(Circle().fill(Theme.surface)).overlay(Circle().strokeBorder(Theme.line))
                                .offset(x: 3, y: 3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .onHover { hoverPic = $0 }
            .help("Change picture (or drop an image here)")
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first else { return false }
                state.setAvatar(id, from: u)
                return true
            }
            VStack(alignment: .leading, spacing: 1) {
                if editing {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                        .frame(maxWidth: 170)
                        .onSubmit { rename(draft); editing = false }
                        .onExitCommand { editing = false }
                } else {
                    Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        .onTapGesture { draft = label; editing = true }
                        .help("Click to rename")
                }
                Text(detail.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.micro).foregroundStyle(Theme.subtle).lineLimit(1)
            }
            Spacer()
            if let remove {
                HoverButton(title: "Remove", icon: "trash", tone: .danger) { remove() }
            }
        }
        .padding(.horizontal, 12).frame(height: 50)
    }
}
