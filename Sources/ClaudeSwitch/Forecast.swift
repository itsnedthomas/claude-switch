import Foundation

/// Both plans' weekly limits added together: they reset at the same moment, so the
/// combined figure is the average of the accounts' weekly percentages.
struct WeekForecast {
    var start: Date
    var reset: Date
    var current: Double            // combined % used now
    var shouldBe: Double           // where an even pace would have you now
    var atReset: Double            // projected % at reset at this week's pace so far
    var runsOut: Date?             // when the combined limit hits 100%, if before reset
    var actual: [(Date, Double)]   // combined % through the week

    static let week: TimeInterval = 7 * 86_400

    static func make(ids: [String], usage: [String: Usage], samples: [Sample], now: Date = Date()) -> WeekForecast? {
        let windows = ids.compactMap { usage[$0]?.weekly }
        guard !windows.isEmpty, windows.count == ids.count, let reset = windows.compactMap(\.resetsAt).max() else { return nil }
        let start = reset.addingTimeInterval(-week)
        let current = windows.map(\.percent).reduce(0, +) / Double(windows.count)
        let elapsed = max(now.timeIntervalSince(start), 60)
        let rate = current / elapsed
        let left = reset.timeIntervalSince(now)
        var runsOut: Date?
        if rate > 0, current < 100 {
            let t = now.addingTimeInterval((100 - current) / rate)
            if t < reset { runsOut = t }
        }
        var actual: [(Date, Double)] = [(start, 0)]
        for s in samples where s.t > start && s.t <= now {
            let vals = ids.compactMap { s.week[$0] }
            // Only readings with every account, or the average jumps about.
            if vals.count == ids.count { actual.append((s.t, vals.reduce(0, +) / Double(vals.count))) }
        }
        actual.append((now, current))
        return WeekForecast(start: start, reset: reset, current: current,
                            shouldBe: min(100, elapsed / week * 100),
                            atReset: current + rate * max(left, 0), runsOut: runsOut, actual: actual)
    }
}

/// When a 5-hour window runs dry at its pace so far, if that's before it resets.
func fiveHourRunsOut(_ w: Window, now: Date = Date()) -> Date? {
    guard let reset = w.resetsAt, w.percent > 0, w.percent < 100 else { return nil }
    let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-5 * 3600))
    guard elapsed > 15 * 60 else { return nil }      // too early to call
    let t = now.addingTimeInterval((100 - w.percent) / (w.percent / elapsed))
    return t < reset ? t : nil
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

/// `length` is the window's length (5 hours or 7 days). Too early in a window
/// (under 15 minutes, or a day of a week) there's no pace to go on yet.
func outlook(_ w: Window?, length: TimeInterval, now: Date = Date()) -> Outlook {
    guard let w, let reset = w.resetsAt, reset > now else { return Outlook() }
    if w.percent >= 100 { return Outlook(atReset: 100, runsOut: now, tone: .out) }
    let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-length))
    guard elapsed > (length > 86_400 ? 24 * 3600 : 15 * 60), w.percent > 0 else {
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
