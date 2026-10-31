import AppKit
import Combine
import SwiftUI

/// True when run with --snapshot or --scan: no menu bar item, no network.
let isTool = ["--snapshot", "--scan", "--film"].contains { CommandLine.arguments.contains($0) }

/// The live account's weekly bar, outlined to its full length so you can see how much is left.
func weekBar(_ pct: Double?, x: CGFloat, y: CGFloat, ink: NSColor) {
    let track = NSRect(x: x, y: y, width: 17.5, height: 6)
    ink.setStroke()
    let outline = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
    outline.lineWidth = 1
    outline.stroke()
    let w = 17.5 * CGFloat(min(max(pct ?? 0, 0), 100) / 100)
    if w > 0 {
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: max(w, 6), height: 6), xRadius: 3, yRadius: 3).fill()
    }
}

func usageBars(week: Double?) -> NSImage {
    let img = NSImage(size: NSSize(width: 19, height: 14), flipped: false) { _ in
        weekBar(week, x: 0.75, y: 4, ink: .black)
        return true
    }
    img.isTemplate = true
    return img
}

/// The live account's round picture, then its weekly bar. The bar follows the menu
/// bar's text colour (drawn at display time), the picture keeps its colours.
func menuBarImage(photo: NSImage, week: Double?) -> NSImage {
    let img = NSImage(size: NSSize(width: 16 + 5 + 19, height: 16), flipped: false) { _ in
        let circle = NSRect(x: 0, y: 0, width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: circle).addClip()
        NSColor.white.setFill(); circle.fill()
        photo.draw(in: circle)
        NSGraphicsContext.restoreGraphicsState()
        weekBar(week, x: 21.75, y: 5, ink: .labelColor)
        return true
    }
    img.isTemplate = false
    return img
}

/// A borderless panel that takes clicks and typing.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click straight away, rather than spending it on focusing the panel.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The menu bar item and the panel under it. The window is the card: the width is
/// fixed, the height eases to each tab, and it carries the system shadow.
@MainActor
final class PanelController: NSObject {
    let state: AppState
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: FloatingPanel
    private var height: CGFloat = 330
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var bag = Set<AnyCancellable>()
    private static let width: CGFloat = 400
    /// An off-screen copy of the panel, used only to measure each tab's height.
    private var measurer: NSHostingView<AnyView>!

    init(state: AppState) {
        self.state = state
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 330),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = false

        // In a (non-scrolling) scroll view so the content is always pinned to the top,
        // even while the window is shorter than it mid-animation.
        let root = ScrollView(.vertical) { PanelView().environmentObject(state) }
            .scrollDisabled(true)
            .scrollIndicators(.never)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line).allowsHitTesting(false))
        let host = FirstClickHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        measurer = NSHostingView(rootView: AnyView(PanelView(resetOnAppear: false).environmentObject(state)))
        measurer.frame = NSRect(x: 0, y: 0, width: Self.width, height: 300)

        if let b = item.button {
            b.target = self
            b.action = #selector(toggle)
            b.imagePosition = .imageLeading
        }
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateButton()
                self?.remeasure()
            }
            .store(in: &bag)
        updateButton()
        // Test hooks (scripts/panel-test.swift): open/close, click, set a tab. Off
        // unless turned on with `defaults write com.claudeswitch.app testHooks -bool yes`.
        guard UserDefaults.standard.bool(forKey: "testHooks") else { return }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(toggle), name: .init("com.claudeswitch.app.toggle"), object: nil)
        dnc.addObserver(self, selector: #selector(clickTest(_:)), name: .init("com.claudeswitch.app.click"), object: nil)
        dnc.addObserver(self, selector: #selector(tabTest(_:)), name: .init("com.claudeswitch.app.tab"), object: nil)
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : show()
    }

    /// Sends a real mouse down/up through the window at a point measured from the
    /// panel's top-left, then logs which tab is showing.
    @objc private func clickTest(_ n: Notification) {
        let parts = (n.object as? String ?? "150,30").split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, panel.isVisible else { state.log("test: panel not visible"); return }
        let p = NSPoint(x: parts[0], y: panel.frame.height - parts[1])
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                panel.sendEvent(e)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.log("test: clicked \(Int(parts[0])),\(Int(parts[1])) -> tab \(self.state.tab.rawValue), height \(Int(self.panel.frame.height)), key \(self.panel.isKeyWindow), alpha \(self.panel.alphaValue), occluded \(!self.panel.occlusionState.contains(.visible)), frame \(self.panel.frame), fitting \(self.panel.contentView?.fittingSize ?? .zero)")
            }
        }
    }

    @objc private func tabTest(_ n: Notification) {
        if let t = Tab(rawValue: (n.object as? String ?? "").capitalized) { state.tab = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.log("test: set tab \(self.state.tab.rawValue) -> height \(Int(self.panel.frame.height)), measured \(Int(self.height)), occluded \(!self.panel.occlusionState.contains(.visible))")
            }
        }
    }

    private func show() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { state.tab = .accounts }
        state.refreshIfStale()
        panel.setFrame(frame(for: height), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        panel.invalidateShadow()
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, self?.panel.firstResponder is NSTextView == false { self?.hide(); return nil }
            return e
        } as Any)
    }

    private func hide() {
        guard panel.isVisible else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        })
    }

    private func remeasure() {
        measurer.layoutSubtreeIfNeeded()
        fit(measurer.fittingSize.height)
    }

    /// New content height: the window (and with it the white card) eases to fit,
    /// its top edge staying under the menu bar.
    private func fit(_ h: CGFloat) {
        guard h > 0, abs(h - height) > 0.5 else { return }
        height = h
        guard panel.isVisible else { return }
        var f = panel.frame
        let top = f.maxY
        f.size.height = min(h, top - (panel.screen?.visibleFrame.minY ?? 0) - 6)
        f.origin.y = top - f.height
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(f, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        })
    }

    /// Hangs the panel from the menu bar on the screen the mouse is on (every display
    /// has its own menu bar, and the item's own window can report another one).
    private func frame(for h: CGFloat) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        var midX = mouse.x
        if let b = item.button, let win = b.window, win.screen == screen {
            midX = win.convertToScreen(b.convert(b.bounds, to: nil)).midX
        }
        let area = screen.visibleFrame
        let top = area.maxY - 6
        let x = min(max(midX - Self.width / 2, area.minX + 6), area.maxX - Self.width - 6)
        let height = min(h, top - area.minY - 6)
        return NSRect(x: x, y: top - height, width: Self.width, height: height)
    }

    // What the menu bar shows right now, and where it's easing to.
    private var shownWeek: Double?
    private var target: (week: Double?, name: String)?
    private var ticker: Timer?
    private var drawnAvatars = -1

    /// The bar, then the live account's first name and weekly %. When the number
    /// changes (a switch, a refresh) the bar slides and the % counts up or down.
    private func updateButton() {
        let u = state.activeID.flatMap { state.usage[$0] }
        // With a picture set, the picture says whose account it is; otherwise the first name.
        let hasPhoto = state.activeID.flatMap { state.avatar($0) } != nil
        let name = state.accounts.count > 1 && !hasPhoto ? state.active.map { String($0.label.split(separator: " ").first ?? "") + " " } ?? "" : ""
        let next = (week: u?.weekly?.percent, name: name + (state.activeID ?? ""))
        if let t = target, t.week == next.week, t.name == next.name, state.avatarVersion == drawnAvatars { return }
        drawnAvatars = state.avatarVersion
        target = next
        guard let fromWeek = shownWeek, let toWeek = next.week else {
            shownWeek = next.week
            draw(week: next.week, name: name)
            return
        }
        let start = Date(), duration = 0.7
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(start) / duration)
                let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2       // ease in-out
                self.shownWeek = fromWeek + (toWeek - fromWeek) * e
                self.draw(week: self.shownWeek, name: name)
                if t >= 1 { timer.invalidate() }
            }
        }
    }

    private func draw(week: Double?, name: String) {
        guard let b = item.button else { return }
        let photo = state.activeID.flatMap { state.avatar($0) }
        b.image = photo.map { menuBarImage(photo: $0, week: week) } ?? usageBars(week: week)
        let label = String(name.prefix(while: { $0 != " " })) + (name.contains(" ") ? " " : "")
        let text = week.map { "\(label)\(Int($0.rounded()))%" } ?? "Claude"
        let title = NSAttributedString(string: " " + text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)])
        if b.attributedTitle != title { b.attributedTitle = title }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PanelController?
    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        if args.contains("--scan") {
            let t = Date()
            let a = ActivityScanner(dir: AppState.support).scan()
            print("hours \(a.cost.count), \(dollars(a.cost.values.reduce(0, +))), \(tokens(a.tokens.values.reduce(0, +))) tokens, \(String(format: "%.1f", Date().timeIntervalSince(t)))s")
            exit(0)
        }
        if let i = args.firstIndex(of: "--film"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in await Film.run(out: out) }
            return
        }
        // `--snapshot out.png [--tab usage]` renders the panel from saved data and quits.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let tab = args.firstIndex(of: "--tab").flatMap { j in j + 1 < args.count ? Tab(rawValue: args[j + 1].capitalized) : nil } ?? .accounts
            snapshot(to: args[i + 1], tab: tab)
            return
        }
        // One copy at a time: a fresh launch replaces any older one.
        if let id = Bundle.main.bundleIdentifier {
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: id) where other != .current { other.terminate() }
        }
        // `--demo` runs the live menu bar on made-up accounts, for trying the UI.
        controller = PanelController(state: AppState(demo: args.contains("--demo")))
    }

    private func snapshot(to path: String, tab: Tab) {
        animateIn = false
        let s = AppState(offline: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            s.tab = tab
            try? await Task.sleep(for: .seconds(0.3))
            let host = NSHostingView(rootView: PanelView(resetOnAppear: false).environmentObject(s).fixedSize(horizontal: false, vertical: true)
                .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line)).padding(8))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .aqua)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}

@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
