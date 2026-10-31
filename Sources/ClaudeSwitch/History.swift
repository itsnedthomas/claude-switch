import Foundation

/// One usage reading for every account, taken on each fetch. (Older lines also
/// carry a 5-hour figure, which is ignored.)
struct Sample: Codable {
    var t: Date
    var week: [String: Double]
}

/// history.jsonl in Application Support: one Sample per line, 35 days kept.
final class History {
    private let url: URL
    private(set) var samples: [Sample] = []
    private let keep: TimeInterval = 35 * 86_400

    init(dir: URL) {
        url = dir.appendingPathComponent("history.jsonl")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            samples = text.split(separator: "\n").compactMap { try? dec.decode(Sample.self, from: Data($0.utf8)) }
        }
        let cutoff = Date().addingTimeInterval(-keep)
        if samples.first.map({ $0.t < cutoff }) == true {
            samples.removeAll { $0.t < cutoff }
            rewrite()
        }
    }

    func append(_ s: Sample) {
        samples.append(s)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard var line = try? enc.encode(s) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    private func rewrite() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let text = samples.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Hourly spend from Claude Code's transcripts, priced at API rates.
struct Activity: Codable, Equatable {
    var cost: [Int: Double] = [:]      // hour start (unix seconds) -> dollars
    var tokens: [Int: Double] = [:]    // hour start -> every token processed, cache reads included
    var loaded = false
}

/// $ per million tokens: input, output, cache read. Cache writes are 1.25x input
/// (5-minute) or 2x input (1-hour).
func price(_ model: String) -> (input: Double, output: Double, read: Double) {
    if model.contains("fable") || model.contains("mythos") { return (10, 50, 0.25) }
    if model.contains("opus-5-5") { return (4, 20, 0.20) }
    if model.contains("opus") { return (5, 25, 0.5) }
    if model.contains("sonnet-4") { return (3, 15, 0.3) }
    if model.contains("sonnet") { return (2, 10, 0.2) }
    if model.contains("haiku-5") { return (0.1, 0.5, 0.01) }
    if model.contains("haiku") { return (1, 5, 0.1) }
    return (5, 25, 0.5)
}

/// Reads ~/.claude/projects incrementally: each file is picked up from where the
/// last scan stopped, so only the first scan is slow.
final class ActivityScanner: @unchecked Sendable {
    struct Cache: Codable {
        var version = 3
        var offsets: [String: UInt64] = [:]
        var lastID: [String: String] = [:]
        var cost: [Int: Double] = [:]
        var tokens: [Int: Double] = [:]
    }

    private let cacheURL: URL
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var cache = Cache()
    private let keepDays = 35.0

    init(dir: URL) {
        cacheURL = dir.appendingPathComponent("activity-v2.json")
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("activity.json"))
        if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d), c.version == 3 { cache = c }
    }

    /// Blocking; call off the main thread.
    func scan() -> Activity {
        let cutoff = Date().addingTimeInterval(-keepDays * 86_400)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return Activity(cost: cache.cost, tokens: cache.tokens, loaded: true)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let needle = Data("\"output_tokens\"".utf8)
        var seen = Set<String>()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let mod = vals?.contentModificationDate, mod > cutoff, let size = vals?.fileSize else { continue }
            let path = url.path
            seen.insert(path)
            var offset = cache.offsets[path] ?? 0
            if UInt64(size) < offset { offset = 0 }       // rewritten
            guard UInt64(size) > offset, let h = try? FileHandle(forReadingFrom: url) else { continue }
            try? h.seek(toOffset: offset)
            let data = h.readDataToEndOfFile()
            try? h.close()
            guard let lastNL = data.lastIndex(of: 0x0A) else { continue }
            var lastID = cache.lastID[path]
            var start = data.startIndex
            while start <= lastNL {
                let end = data[start...lastNL].firstIndex(of: 0x0A) ?? lastNL
                let line = data[start..<end]
                start = end + 1
                // Cheap filter before decoding: only assistant lines carry usage.
                guard line.count > 200, line.range(of: needle) != nil,
                      let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let ts = (obj["timestamp"] as? String).flatMap(iso.date) else { continue }
                let id = msg["id"] as? String
                if let id, id == lastID { continue }        // one reply is written as several lines
                lastID = id
                func n(_ d: [String: Any]?, _ k: String) -> Double { (d?[k] as? NSNumber)?.doubleValue ?? 0 }
                let p = price(msg["model"] as? String ?? "")
                let input = n(usage, "input_tokens"), output = n(usage, "output_tokens")
                let read = n(usage, "cache_read_input_tokens"), write = n(usage, "cache_creation_input_tokens")
                let split = usage["cache_creation"] as? [String: Any]
                let w5 = split == nil ? write : n(split, "ephemeral_5m_input_tokens")
                let w1h = n(split, "ephemeral_1h_input_tokens")
                let dollars = (input * p.input + output * p.output + read * p.read + w5 * p.input * 1.25 + w1h * p.input * 2) / 1_000_000
                let hour = Int(ts.timeIntervalSince1970) / 3600 * 3600
                cache.cost[hour, default: 0] += dollars
                cache.tokens[hour, default: 0] += input + output + read + write
            }
            cache.offsets[path] = offset + UInt64(data.distance(from: data.startIndex, to: lastNL) + 1)
            cache.lastID[path] = lastID
        }
        cache.offsets = cache.offsets.filter { seen.contains($0.key) }
        cache.lastID = cache.lastID.filter { seen.contains($0.key) }
        let oldest = Int(cutoff.timeIntervalSince1970)
        cache.cost = cache.cost.filter { $0.key >= oldest }
        cache.tokens = cache.tokens.filter { $0.key >= oldest }
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
        return Activity(cost: cache.cost, tokens: cache.tokens, loaded: true)
    }
}
