import Foundation

typealias JSON = [String: Any]

struct ShellResult {
    let status: Int32
    let out: String
    let err: String
}

@discardableResult
func shell(_ path: String, _ args: [String], stdin: String? = nil) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe(), input = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = stdin == nil ? FileHandle.nullDevice : input
    do { try p.run() } catch { return ShellResult(status: -1, out: "", err: "\(error)") }
    if let stdin {
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
    }
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ShellResult(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
}

func parseJSON(_ s: String) -> JSON? {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? JSON
}

func encodeJSON(_ j: JSON) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: j, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: d, as: UTF8.self)
}

/// Goes through /usr/bin/security, exactly as Claude Code does, so the items it
/// created stay readable without keychain prompts.
enum Keychain {
    static let user: String = {
        let u = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        return u.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil ? u : "claude-code-user"
    }()

    static func read(_ service: String, account: String = user) -> String? {
        let r = shell("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"])
        guard r.status == 0 else { return nil }
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Writes, then reads back to confirm. Small payloads go over stdin so the
    /// secret never shows in `ps`; big ones fall back to argv like Claude Code.
    @discardableResult
    static func write(_ service: String, account: String = user, value: String) -> Bool {
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        if line.count <= 4000 {
            shell("/usr/bin/security", ["-i"], stdin: line)
        } else {
            shell("/usr/bin/security", ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        }
        return read(service, account: account) == value
    }

    static func delete(_ service: String, account: String = user) {
        shell("/usr/bin/security", ["delete-generic-password", "-s", service, "-a", account])
    }

    /// Every "Claude Code-credentials…" service name in the login keychain.
    static func claudeServices() -> Set<String> {
        let r = shell("/usr/bin/security", ["dump-keychain"])
        var found = Set<String>()
        let pattern = #""svce"<blob>="(Claude Code-credentials[^"]*)""#
        let re = try! NSRegularExpression(pattern: pattern)
        for m in re.matches(in: r.out, range: NSRange(r.out.startIndex..., in: r.out)) {
            if let range = Range(m.range(at: 1), in: r.out) { found.insert(String(r.out[range])) }
        }
        return found
    }
}

/// The login Claude Code (and so Conductor) is using right now.
enum Live {
    static let service = "Claude Code-credentials"

    static func read() -> JSON? { Keychain.read(service).flatMap(parseJSON) }

    static func write(_ j: JSON) -> Bool { Keychain.write(service, value: encodeJSON(j)) }
}

/// Our saved copy of each account: {"claudeAiOauth": {...}, "oauthAccount": {...}}.
enum Stash {
    static let service = "ClaudeSwitch"

    static func read(_ id: String) -> JSON? { Keychain.read(service, account: id).flatMap(parseJSON) }

    @discardableResult
    static func write(_ id: String, _ j: JSON) -> Bool { Keychain.write(service, account: id, value: encodeJSON(j)) }

    static func delete(_ id: String) { Keychain.delete(service, account: id) }
}

/// ~/.claude.json holds `oauthAccount`, which is who Claude Code says you are.
enum ClaudeConfig {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")

    static func oauthAccount(at url: URL = url) -> JSON? {
        guard let d = try? Data(contentsOf: url),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { return nil }
        return j["oauthAccount"] as? JSON
    }

    static func setOAuthAccount(_ account: JSON) throws {
        let d = try Data(contentsOf: url)
        guard var j = try JSONSerialization.jsonObject(with: d) as? JSON else { return }
        j["oauthAccount"] = account
        let out = try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
