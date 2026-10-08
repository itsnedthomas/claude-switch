import Foundation

/// One planned 5-hour window: when a one-token message should start it.
struct PlannedWindow: Identifiable {
    let id: String          // "yyyy-MM-dd|account|n", also the kick-off log key
    let account: Account
    let start: Date
    var end: Date { start.addingTimeInterval(5 * 3600) }
}

/// Session planning. Working hours are covered by every scheduled account's
/// 5-hour windows, staggered by 5h ÷ accounts so a fresh window opens that often.
/// The last account starts at the start of work, each earlier one a stagger
/// before it (two accounts and a 09:00 start: 06:30 and 09:00, resets at 11:30
/// and 14:00). Each window's start gets its own random delay.
extension AppState {
    /// Accounts in the schedule, default first.
    var scheduled: [Account] {
        let order = accounts.filter { $0.id == defaultID } + accounts.filter { $0.id != defaultID }
        return order.filter { !scheduleOff.contains($0.id) }
    }

    func inSchedule(_ id: String) -> Bool { !scheduleOff.contains(id) }

    func setInSchedule(_ id: String, _ on: Bool) {
        scheduleOff = on ? scheduleOff.filter { $0 != id } : scheduleOff + [id]
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func isOffDay(_ d: Date) -> Bool { kickoffWeekdays && Calendar.current.isDateInWeekend(d) }

    /// The plan for one day. Random delays are rolled once per window and kept.
    func plan(for day: Date) -> [PlannedWindow] {
        let accts = scheduled
        guard !accts.isEmpty else { return [] }
        let dayStart = Calendar.current.startOfDay(for: day)
        let work = dayStart.addingTimeInterval(Double(workStart) * 60)
        let end = dayStart.addingTimeInterval(Double(max(workEnd, workStart + 30)) * 60)
        let stagger = 5 * 3600 / Double(accts.count)
        let key = Self.dayKey(day)
        let now = Date()
        let today = Calendar.current.isDate(day, inSameDayAs: now)
        var out: [PlannedWindow] = []
        func jittered(_ id: String, _ t: Date) -> Date {
            var jitter = Double(kickoffLog[id + "|j"] ?? "")
            if jitter == nil {
                jitter = Double.random(in: 60...(Double(max(1, kickoffJitterMax)) * 60))
                kickoffLog[id + "|j"] = String(Int(jitter!))
            }
            return t.addingTimeInterval(jitter!)
        }
        for (i, acct) in accts.enumerated() {
            var chain: [PlannedWindow] = []
            var t = work.addingTimeInterval(-Double(accts.count - 1 - i) * stagger)
            var n = 0
            while t < end {
                let id = "\(key)|\(acct.id)|\(n)"
                chain.append(PlannedWindow(id: id, account: acct, start: jittered(id, t)))
                t = t.addingTimeInterval(5 * 3600)
                n += 1
            }
            // Today, follow what's really happening: the window this account is in now,
            // then the next ones from its real reset, every 5 hours.
            if today, let reset = usage[acct.id]?.fiveHour?.resetsAt, reset > now {
                let realStart = reset.addingTimeInterval(-5 * 3600)
                chain = chain.filter { $0.end <= realStart }
                chain.append(PlannedWindow(id: "\(key)|\(acct.id)|now", account: acct, start: realStart))
                var t = reset, m = 0
                while t < end {
                    let id = "\(key)|\(acct.id)|r\(m)"
                    chain.append(PlannedWindow(id: id, account: acct, start: jittered(id, t)))
                    t = t.addingTimeInterval(5 * 3600)
                    m += 1
                }
            }
            out += chain
        }
        return out.sorted { $0.start < $1.start }
    }

    /// The day the schedule view shows: today until work ends, then the next working day.
    func planDay(now: Date = Date()) -> Date {
        var day = now
        let todayEnd = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(workEnd) * 60)
        if now > todayEnd || isOffDay(now) {
            repeat { day = Calendar.current.date(byAdding: .day, value: 1, to: day)! } while isOffDay(day)
        }
        return day
    }

    func nextKickoff(now: Date = Date()) -> PlannedWindow? {
        guard kickoffOn else { return nil }
        for offset in 0..<8 {
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: now), !isOffDay(day) else { continue }
            if let w = plan(for: day).first(where: { $0.start > now && kickoffLog[$0.id] != "done" }) { return w }
        }
        return nil
    }

    func checkKickoffs() async {
        guard !offline else { return }
        let now = Date()
        guard kickoffOn, !isOffDay(now) else { return }
        for w in plan(for: now) where kickoffLog[w.id] != "done" && now >= w.start {
            // An hour late (the Mac was asleep) and it's no longer worth starting.
            if now.timeIntervalSince(w.start) > 3600 { kickoffLog[w.id] = "done"; continue }
            // Already inside a window: nothing to start.
            if let r = usage[w.account.id]?.fiveHour?.resetsAt, r > now { kickoffLog[w.id] = "done"; continue }
            do {
                usage[w.account.id] = try await API.kickoff(try await token(for: w.account))
                kickoffLog[w.id] = "done"
                log("started \(w.account.label)'s window (planned \(clock(w.start)))")
                notify("Started \(w.account.label)'s 5-hour window", body: "It resets around \(clock(w.end)).")
            } catch {
                errors[w.account.id] = "Couldn't start its window: \(error.localizedDescription)"
            }
        }
        // Keep a few days either side.
        let days = Set((-3..<9).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: now) }.map(Self.dayKey))
        let pruned = kickoffLog.filter { days.contains(String($0.key.prefix(10))) }
        if pruned.count != kickoffLog.count { kickoffLog = pruned }
    }
}
