import Foundation

/// Every plan's weekly limit, each on its own clock. Plans added at different
/// times reset at different moments, so each is read and projected from its own
/// window, and the pool verdict asks whether, moving between them, you'd run out
/// of all of them before one resets.
struct WeekForecast {
    struct Plan: Identifiable {
        var id: String
        var label: String
        var start: Date
        var reset: Date
        var current: Double             // % used now
        var rate: Double                // % per second at its pace so far
        var runsOut: Date?              // when it hits 100% at that pace, if before reset
        var actual: [(Date, Double)]    // % through its window
        var atReset: Double { current + rate * max(reset.timeIntervalSinceNow, 0) }

        /// Used % at a moment: from the readings so far, projected after now.
        func value(at d: Date, now: Date = Date()) -> Double? {
            guard d >= start, d <= reset else { return nil }
            if d >= now { return min(100, current + rate * d.timeIntervalSince(now)) }
            return actual.last(where: { $0.0 <= d })?.1 ?? 0
        }
    }

    var plans: [Plan]                   // plans with a week running
    /// Other tools' weekly limits: drawn beside the plans, left out of the totals.
    var extras: [Plan] = []
    var count: Int                      // every plan with a reading, started or not
    var current: Double                 // average % used across them
    var shouldBe: Double                // where even pacing would have the average now
    var start: Date                     // chart: earliest week start
    var end: Date                       // chart: latest reset
    var poolRunsOut: Date?              // every plan out at once, if before `end`
    /// Every plan resets together, so one even-pace line fits them all.
    var sharedReset: Bool

    static let week: TimeInterval = 7 * 86_400

    /// Average % used across every plan at a moment, projected after now. A plan
    /// outside its week counts as unused.
    func combined(at d: Date, now: Date = Date()) -> Double {
        plans.map { $0.value(at: d, now: now) ?? 0 }.reduce(0, +) / Double(max(count, 1))
    }

    /// The combined line: every reading so far, then hourly to the chart's end.
    func combinedSeries(now: Date = Date()) -> (actual: [(Date, Double)], ahead: [(Date, Double)]) {
        let times = Set(plans.flatMap { $0.actual.map(\.0) }).filter { $0 < now }.sorted()
        let actual = times.map { ($0, combined(at: $0, now: now)) } + [(now, combined(at: now, now: now))]
        var ahead = [(now, combined(at: now, now: now))]
        var t = now
        while t < end { t = min(t + 3600, end); ahead.append((t, combined(at: t, now: now))) }
        return (actual, ahead)
    }

    static func make(accounts: [(id: String, label: String)], usage: [String: Usage], samples: [Sample],
                     others: [(id: String, label: String, weekly: Window)] = [], now: Date = Date()) -> WeekForecast? {
        var plans: [Plan] = []
        var used: [Double] = [], pace: [Double] = []
        for a in accounts {
            guard let u = usage[a.id] else { continue }      // no reading yet: leave it out
            guard let w = u.weekly, let plan = plan(a.id, a.label, w, samples: samples, now: now) else {
                used.append(0); pace.append(0)               // its week starts when it's next used
                continue
            }
            plans.append(plan)
            used.append(w.percent)
            pace.append(min(100, now.timeIntervalSince(plan.start) / week * 100))
        }
        let extras = others.compactMap { plan($0.id, $0.label, $0.weekly, samples: samples, now: now) }
        guard !plans.isEmpty else { return nil }
        let all = plans + extras
        let resets = all.map(\.reset)
        let end = resets.max()!
        return WeekForecast(plans: plans, extras: extras, count: used.count,
                            current: used.reduce(0, +) / Double(used.count),
                            shouldBe: pace.reduce(0, +) / Double(pace.count),
                            start: all.map(\.start).min()!, end: end,
                            poolRunsOut: poolRunsOut(plans: plans, idle: used.count - plans.count, until: end, now: now),
                            sharedReset: end.timeIntervalSince(resets.min()!) < 3600)
    }

    /// One weekly window read and projected on its own clock, or nil when its week isn't running.
    static func plan(_ id: String, _ label: String, _ w: Window, samples: [Sample], now: Date) -> Plan? {
        guard let reset = w.resetsAt, reset > now else { return nil }
        let start = reset.addingTimeInterval(-week)
        let elapsed = now.timeIntervalSince(start)
        // Under a day in, a few busy hours would project as running out: pace it as a day.
        let rate = w.percent / max(elapsed, 86_400)
        var runsOut: Date?
        if w.percent >= 100 {
            runsOut = now
        } else if rate > 0 {
            let t = now.addingTimeInterval((100 - w.percent) / rate)
            if t < reset { runsOut = t }
        }
        var actual: [(Date, Double)] = [(start, 0)]
        for s in samples where s.t > start && s.t < now {
            // A reading every 15 minutes at most keeps the chart light with several plans.
            if let v = s.week[id], s.t.timeIntervalSince(actual.last!.0) >= 900 { actual.append((s.t, v)) }
        }
        actual.append((now, w.percent))
        return Plan(id: id, label: label, start: start, reset: reset, current: w.percent,
                    rate: rate, runsOut: runsOut, actual: actual)
    }

    /// Spends every plan's combined pace from whichever plan has the most room
    /// (what auto-switch does), refilling each at its reset. A plan whose week
    /// hasn't started is a full one whose week starts when it's first drawn on.
    static func poolRunsOut(plans: [Plan], idle: Int, until end: Date, now: Date) -> Date? {
        let burn = plans.map(\.rate).reduce(0, +)
        guard burn > 0 else { return nil }
        var used = plans.map(\.current) + Array(repeating: 0, count: idle)
        var reset: [Date?] = plans.map(\.reset) + Array(repeating: nil, count: idle)
        let step: TimeInterval = 600
        var t = now
        while t < end {
            t += step
            for i in used.indices { if let r = reset[i], t >= r { used[i] = 0; reset[i] = r + week } }
            var need = burn * step
            while need > 0.0001 {
                guard let i = used.indices.filter({ used[$0] < 100 }).min(by: { used[$0] < used[$1] }) else { return t }
                let take = min(need, 100 - used[i])
                used[i] += take
                need -= take
                if reset[i] == nil { reset[i] = t + week }
            }
        }
        return nil
    }
}

/// "16:46", "tomorrow 06:37", "Sat 09:00", "15 Oct 01:59".
func clock(_ d: Date) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    let time = f.string(from: d)
    if cal.isDateInToday(d) { return time }
    if cal.isDateInTomorrow(d) { return "tomorrow \(time)" }
    if cal.isDateInYesterday(d) { return "yesterday \(time)" }
    f.dateFormat = abs(d.timeIntervalSinceNow) < 6 * 86_400 ? "EEE HH:mm" : "d MMM HH:mm"
    return f.string(from: d)
}

func span(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    if m < 60 { return "\(m)m" }
    if m < 24 * 60 { return "\(m / 60)h \(m % 60)m" }
    return "\(m / 1440)d \((m % 1440) / 60)h"
}

/// Where a window is heading at its pace so far.
struct Outlook {
    enum Tone { case fine, close, out }
    var atReset: Double?        // % at reset
    var runsOut: Date?          // when it hits 100%, if before reset
    var tone: Tone = .fine
}

/// `length` is the window's length. Too early in a window (a quarter of it, at
/// most a day) there's no pace to go on yet.
func outlook(_ w: Window?, length: TimeInterval, now: Date = Date()) -> Outlook {
    guard let w, let reset = w.resetsAt, reset > now else { return Outlook() }
    if w.percent >= 100 { return Outlook(atReset: 100, runsOut: now, tone: .out) }
    let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-length))
    guard elapsed > min(86_400, length / 4), w.percent > 0 else {
        return Outlook(tone: w.percent >= 90 ? .close : .fine)
    }
    let rate = w.percent / elapsed
    let atReset = w.percent + rate * reset.timeIntervalSince(now)
    let out = atReset >= 100 ? now.addingTimeInterval((100 - w.percent) / rate) : nil
    let tone: Outlook.Tone = atReset >= 110 || w.percent >= 95 ? .out : atReset >= 85 ? .close : .fine
    return Outlook(atReset: atReset, runsOut: out, tone: tone)
}

/// "Thu 8 Oct, 19:00".
func fullDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "EEE d MMM, HH:mm"
    return f.string(from: d)
}
