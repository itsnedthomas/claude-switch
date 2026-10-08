import AppKit
import SwiftUI

/// Renders the README / landing-page media (at 3x) from the real UI with made-up data:
/// `ClaudeSwitch --film <dir>` writes PNG frames and stills; scripts/media.sh
/// turns them into MP4 and GIF. Every frame is the app's own views.
@MainActor
enum Film {
    static let fps = 60.0
    /// Pixels per point: 3x for crisp stills and video on any screen.
    static let scale: CGFloat = 3
    static let stage = NSSize(width: 800, height: 820)        // points; drawn at `scale`
    static let panelWidth: CGFloat = 400
    static let menuBarHeight: CGFloat = 30
    static let itemMidX: CGFloat = 330                        // where the menu bar item sits

    static func run(out: URL) async {
        animateIn = false
        let state = AppState(demo: true)
        try? await Task.sleep(for: .seconds(0.5))
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try? fm.createDirectory(at: out.appendingPathComponent("tour"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: out.appendingPathComponent("menubar"), withIntermediateDirectories: true)

        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        NSApp.appearance = NSAppearance(named: .aqua)

        // The tour: each tab revealed, the cursor moving to the next tab and clicking.
        let beats: [(Tab, Double)] = [(.accounts, 3.4), (.usage, 3.8), (.schedule, 3.4), (.settings, 3.2)]
        var heights: [Tab: CGFloat] = [:]
        for (tab, _) in beats { state.tab = tab; filmTime = 10; heights[tab] = panel(state, window).size.height }
        var frame = 0
        var prevHeight = heights[.accounts]!
        for (bi, (tab, length)) in beats.enumerated() {
            state.tab = tab
            let next = bi + 1 < beats.count ? beats[bi + 1].0 : nil
            let n = Int(length * fps)
            for i in 0..<n {
                let t = Double(i) / fps
                filmTime = t
                let content = panel(state, window)
                // The card eases from the last tab's height to this one's.
                let k = ease(min(1, t / 0.3))
                let h = prevHeight + (content.size.height - prevHeight) * k
                // Cursor: rests on this tab, then glides to the next one and clicks.
                let here = tabPoint(tab), there = next.map(tabPoint) ?? here
                let travel = ease(min(1, max(0, (t - (length - 0.9)) / 0.6)))
                let cursor = NSPoint(x: here.x + (there.x - here.x) * travel, y: here.y + (there.y - here.y) * travel)
                let pressed = next != nil && t > length - 0.18
                let img = compose(content: content, cardHeight: h, cursor: cursor, pressed: pressed, state: state)
                write(img, to: out.appendingPathComponent(String(format: "tour/%05d.png", frame)))
                frame += 1
            }
            prevHeight = content(stateTab: tab, state, window).size.height
            // A still of each tab, fully loaded, with no cursor.
            filmTime = 10
            let still = compose(content: panel(state, window), cardHeight: heights[tab]!, cursor: nil, pressed: false, state: state)
            write(crop(still, height: menuBarHeight + 8 + heights[tab]! + 56), to: out.appendingPathComponent("\(tab.rawValue.lowercased()).png"))
            // Just the panel on the ground, for cards on the landing page.
            write(crop(still, rect: NSRect(x: panelX - 28, y: menuBarHeight - 6, width: panelWidth + 56, height: heights[tab]! + 48)),
                  to: out.appendingPathComponent("\(tab.rawValue.lowercased())-panel.png"))
        }

        // The menu bar on a switch: Work at 93% hands over to Personal at 18%.
        let mbFrames = Int(2.6 * fps)
        for i in 0..<mbFrames {
            let t = Double(i) / fps
            let k = ease(min(1, max(0, (t - 0.8) / 0.7)))
            let img = menuBar(t: t, k: k, state: state)
            write(img, to: out.appendingPathComponent(String(format: "menubar/%05d.png", i)))
        }
        filmTime = nil
        print("frames written to \(out.path)")
        exit(0)
    }

    private static func content(stateTab: Tab, _ state: AppState, _ window: NSWindow) -> NSImage {
        filmTime = 10
        return panel(state, window)
    }

    static func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

    /// Centre of a tab in the switcher, in stage points (y from the top).
    static func tabPoint(_ tab: Tab) -> NSPoint {
        let i = CGFloat(Tab.allCases.firstIndex(of: tab)!)
        let trackW = panelWidth - 28 - 6 - 22
        return NSPoint(x: panelX + 14 + 2 + trackW / 8 * (2 * i + 1), y: menuBarHeight + 8 + 14 + 13)
    }

    static var panelX: CGFloat { itemMidX - panelWidth / 2 }

    /// The panel's content at 2x, as the app draws it.
    static func panel(_ state: AppState, _ window: NSWindow) -> NSImage {
        let host = NSHostingView(rootView: PanelView(resetOnAppear: false).environmentObject(state).background(Theme.surface))
        window.contentView = host
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    /// The brand ground (white, soft blue glow, faint grid), a menu bar, and the
    /// panel hanging under its item.
    static func compose(content: NSImage, cardHeight: CGFloat, cursor: NSPoint?, pressed: Bool, state: AppState) -> NSBitmapImageRep {
        let rep = canvas(stage)
        draw(in: rep) {
            ground(NSRect(origin: .zero, size: stage), glowAt: NSPoint(x: itemMidX, y: stage.height - 320))
            menuBarStrip(width: stage.width, state: state, five: state.active.flatMap { state.usage[$0.id]?.fiveHour?.percent },
                         week: state.active.flatMap { state.usage[$0.id]?.weekly?.percent }, avatarID: state.activeID)
            let top = stage.height - menuBarHeight - 8
            let card = NSRect(x: panelX, y: top - cardHeight, width: panelWidth, height: cardHeight)
            let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.16)
            sh.shadowBlurRadius = 30
            sh.shadowOffset = NSSize(width: 0, height: -10)
            sh.set()
            NSColor.white.setFill(); path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            content.draw(in: NSRect(x: card.minX, y: top - content.size.height, width: content.size.width, height: content.size.height))
            NSGraphicsContext.restoreGraphicsState()
            NSColor(srgbRed: 0.87, green: 0.89, blue: 0.91, alpha: 1).setStroke()
            let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
            border.lineWidth = 1
            border.stroke()
            if let c = cursor { drawCursor(at: NSPoint(x: c.x, y: stage.height - c.y), pressed: pressed) }
        }
        return rep
    }

    static func menuBar(t: Double, k: Double, state: AppState) -> NSBitmapImageRep {
        let size = NSSize(width: 520, height: 110)
        let rep = canvas(size)
        let work = state.accounts[0], personal = state.accounts[1]
        let five = 93 + (18 - 93) * k, week = 38 + (17 - 38) * k
        draw(in: rep) {
            ground(NSRect(origin: .zero, size: size), glowAt: NSPoint(x: size.width / 2, y: size.height / 2))
            // A zoomed menu bar: the item in the middle, scaled up 2.5x.
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.scaleBy(x: 2.5, y: 2.5)
            let pill = NSRect(x: -62, y: -15, width: 124, height: 30)
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
            NSColor.black.withAlphaComponent(0.06).setStroke()
            NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).stroke()
            let id = k < 0.5 ? work.id : personal.id
            if let photo = AppState.demoAvatar(id) {
                let img = menuBarImage(photo: photo, five: five, week: week)
                img.draw(in: NSRect(x: -52, y: -8, width: img.size.width, height: img.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1)
            }
            let text = NSAttributedString(string: "\(Int(five.rounded()))%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor])
            text.draw(at: NSPoint(x: -6, y: -8))
            ctx.restoreGState()
        }
        return rep
    }

    static func menuBarStrip(width: CGFloat, state: AppState, five: Double?, week: Double?, avatarID: String?) {
        let bar = NSRect(x: 0, y: stage.height - menuBarHeight, width: width, height: menuBarHeight)
        NSColor.white.withAlphaComponent(0.85).setFill(); bar.fill()
        NSColor.black.withAlphaComponent(0.07).setFill(); NSRect(x: 0, y: bar.minY, width: width, height: 1).fill()
        let midY = bar.midY
        // The app's item: picture, bars, 5-hour %.
        if let id = avatarID, let photo = state.avatar(id) {
            let img = menuBarImage(photo: photo, five: five, week: week)
            let text = NSAttributedString(string: "\(Int((five ?? 0).rounded()))%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.black.withAlphaComponent(0.85)])
            let total = img.size.width + 5 + text.size().width
            let x0 = itemMidX - total / 2
            img.draw(in: NSRect(x: x0, y: midY - 8, width: img.size.width, height: img.size.height))
            text.draw(at: NSPoint(x: x0 + img.size.width + 5, y: midY - text.size().height / 2))
        }
        if let apple = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let tinted = NSImage(size: apple.size, flipped: false) { r in
                apple.draw(in: r); NSColor.black.withAlphaComponent(0.85).set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: 20, y: midY - apple.size.height / 2, width: apple.size.width, height: apple.size.height))
        }
        // A few ordinary menu bar icons and the clock, in grey.
        var x = itemMidX + 64
        for name in ["wifi", "battery.75percent", "magnifyingglass", "switch.2"] {
            if let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
                let tinted = NSImage(size: sym.size, flipped: false) { r in
                    sym.draw(in: r); NSColor.black.withAlphaComponent(0.78).set(); r.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: NSRect(x: x, y: midY - sym.size.height / 2, width: sym.size.width, height: sym.size.height))
                x += sym.size.width + 16
            }
        }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM  HH:mm"
        let clock = NSAttributedString(string: f.string(from: Date()), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black.withAlphaComponent(0.85)])
        clock.draw(at: NSPoint(x: x + 2, y: midY - clock.size().height / 2))
    }

    static func ground(_ r: NSRect, glowAt c: NSPoint) {
        NSColor.white.setFill(); r.fill()
        let glow = NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.55, blue: 1, alpha: 0.13), NSColor(srgbRed: 0.20, green: 0.55, blue: 1, alpha: 0)])!
        glow.draw(fromCenter: c, radius: 0, toCenter: c, radius: max(r.width, r.height) * 0.55, options: [])
        NSColor.black.withAlphaComponent(0.035).setFill()
        var x: CGFloat = 0
        while x < r.width { NSRect(x: x, y: 0, width: 1, height: r.height).fill(); x += 32 }
        var y: CGFloat = 0
        while y < r.height { NSRect(x: 0, y: y, width: r.width, height: 1).fill(); y += 32 }
    }

    static func drawCursor(at p: NSPoint, pressed: Bool) {
        let img = NSCursor.arrow.image
        let s: CGFloat = pressed ? 0.88 : 1
        let hot = NSCursor.arrow.hotSpot
        let w = img.size.width * s, h = img.size.height * s
        img.draw(in: NSRect(x: p.x - hot.x * s, y: p.y - (h - hot.y * s), width: w, height: h))
    }

    static func canvas(_ size: NSSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        return rep
    }

    static func draw(in rep: NSBitmapImageRep, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { body() }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The top `height` points of a stage frame.
    static func crop(_ rep: NSBitmapImageRep, height: CGFloat) -> NSBitmapImageRep {
        let h = min(height, stage.height)
        let out = canvas(NSSize(width: stage.width, height: h))
        draw(in: out) {
            NSImage(cgImage: rep.cgImage!, size: stage).draw(at: NSPoint(x: 0, y: h - stage.height), from: .zero, operation: .copy, fraction: 1)
        }
        return out
    }

    /// A rect of a stage frame, `rect.y` measured from the top.
    static func crop(_ rep: NSBitmapImageRep, rect: NSRect) -> NSBitmapImageRep {
        let out = canvas(rect.size)
        draw(in: out) {
            NSImage(cgImage: rep.cgImage!, size: stage).draw(at: NSPoint(x: -rect.minX, y: rect.height + rect.minY - stage.height),
                                                            from: .zero, operation: .copy, fraction: 1)
        }
        return out
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
