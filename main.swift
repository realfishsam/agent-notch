import AppKit
import ApplicationServices

// MARK: - Model

enum AgentKind: String { case claude = "Claude Code", codex = "Codex", opencode = "OpenCode", hermes = "Hermes" }

struct AgentSession {
    let id: String
    let kind: AgentKind
    let title: String
    let snippet: String
    let model: String
    let lastModified: Date
    var prompt: String = ""
    var threadID: String = ""
    var parentID: String?
    var nickname: String?
    var children: [AgentSession] = []
    var isLive: Bool = false  // process alive (from discovery, never mtime)
    var busyOverride: Bool?
    // last user/assistant entry — housekeeping writes (away_summary etc.)
    // bump the file mtime but must not count as activity
    var lastActivity: Date?
    // hybrid: busy = alive AND conversing; quiet-while-alive is idle, not done
    var isBusy: Bool {
        guard isLive else { return false }
        if let busyOverride { return busyOverride }
        return Date().timeIntervalSince(lastActivity ?? lastModified) < 30
    }
    var anyLive: Bool { isLive || children.contains { $0.isLive } }
    var anyBusy: Bool { isBusy || children.contains { $0.isBusy } }
    var effectiveLastModified: Date { children.reduce(lastModified) { max($0, $1.lastModified) } }
}

// MARK: - Process discovery
// Ported from open-vibe-island's ActiveAgentProcessDiscovery: "a session IS a
// running agent process in a terminal." `ps` finds agent processes (a TTY is
// required, which excludes headless/background sessions), `lsof` maps each
// process to the transcript file it holds open. Liveness comes from the OS,
// never from transcript mtimes.

final class ProcessDiscovery {
    // Claude Code appends-and-closes its transcript, so lsof usually shows no
    // open jsonl for it — open-vibe-island falls back to the process cwd (and
    // claims by tty so a terminal maps to one session). Codex holds its
    // rollout file open, so the path route always works there.
    struct Snapshot { let kind: AgentKind; let transcriptPath: String?; let cwd: String? }

    private static let psTimeout: TimeInterval = 2.0
    private static let lsofTimeout: TimeInterval = 2.0

    func liveTranscripts() -> [Snapshot] {
        guard let psOut = run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,command="], timeout: Self.psTimeout) else { return [] }
        var candidates: [(pid: String, tty: String, kind: AgentKind)] = []
        var out: [Snapshot] = []
        var claimed = Set<String>()
        for line in psOut.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard parts.count == 4 else { continue }
            let pid = String(parts[0]), tty = String(parts[2])
            let command = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { continue }
            let hasTTY = tty != "??"
            let kind: AgentKind
            if isClaude(command) { kind = .claude }
            else if isCodex(command) { kind = .codex }
            else if isOpenCode(command) { kind = .opencode }
            else if isHermes(command) { kind = .hermes }
            else { continue }
            // Claude requires terminal; Codex/OpenCode/Hermes can be desktop apps without TTY
            if kind == .claude, !hasTTY { continue }
            // Codex desktop (no TTY): sentinel without lsof
            if kind == .codex, !hasTTY {
                guard claimed.insert("codex-desktop").inserted else { continue }
                out.append(Snapshot(kind: kind, transcriptPath: nil, cwd: nil))
                continue
            }
            // Hermes: always sentinel (all processes are background, no TTY)
            if kind == .hermes {
                guard claimed.insert("hermes").inserted else { continue }
                out.append(Snapshot(kind: kind, transcriptPath: nil, cwd: nil))
                continue
            }
            candidates.append((pid, tty, kind))
        }
        // Batch lsof for all remaining candidates
        let chunks = lsofChunks(pids: candidates.map(\.pid))
        for (pid, tty, kind) in candidates {
            guard let lsof = chunks[pid] else { continue }
            let cwd = workingDirectory(from: lsof)
            // Claude subagents run in .claude/worktrees/agent-*/
            if kind == .claude, let cwd, cwd.contains("/.claude/worktrees/agent-") { continue }
            switch kind {
            case .claude:
                let path = bestClaudeTranscript(in: lsof, cwd: cwd)
                guard path != nil || cwd != nil else { continue }
                guard claimed.insert("claude:\(path ?? tty)").inserted else { continue }
                out.append(Snapshot(kind: kind, transcriptPath: path, cwd: cwd))
            case .codex:
                if let path = bestCodexTranscript(in: lsof) {
                    guard claimed.insert("codex:\(path)").inserted else { continue }
                    out.append(Snapshot(kind: kind, transcriptPath: path, cwd: cwd))
                } else {
                    // Desktop app (no open JSONL): sentinel for global Codex liveness
                    guard claimed.insert("codex-desktop").inserted else { continue }
                    out.append(Snapshot(kind: kind, transcriptPath: nil, cwd: nil))
                }
            case .opencode:
                guard cwd != nil else { continue }
                guard claimed.insert("opencode:\(tty)").inserted else { continue }
                out.append(Snapshot(kind: kind, transcriptPath: nil, cwd: cwd))
            case .hermes:
                break // unreachable: hermes handled before lsof
            }
        }
        return out
    }

    /// One lsof for all pids; -Fn output is split per-pid on its `p<pid>` markers.
    private func lsofChunks(pids: [String]) -> [String: String] {
        guard !pids.isEmpty,
              let outText = run("/usr/sbin/lsof", ["-a", "-p", pids.joined(separator: ","), "-Fn"], timeout: Self.lsofTimeout) else { return [:] }
        var chunks: [String: String] = [:]
        var curPid: String?
        var cur = ""
        for line in outText.split(whereSeparator: \.isNewline) {
            if line.first == "p" {
                if let p = curPid { chunks[p] = cur }
                curPid = String(line.dropFirst())
                cur = ""
            } else {
                cur += line + "\n"
            }
        }
        if let p = curPid { chunks[p] = cur }
        return chunks
    }

    private func isClaude(_ command: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.contains("/.local/bin/claude") { return true }
        guard let first = lowered.split(separator: " ").first.map(String.init) else { return false }
        return first == "claude" || first.hasSuffix("/claude")
    }

    private func isCodex(_ command: String) -> Bool {
        let lowered = command.lowercased()
        guard let first = lowered.split(separator: " ").first.map(String.init) else { return false }
        return first == "codex" || first.hasSuffix("/codex") || lowered.contains("/codex/codex")
    }

    private func isOpenCode(_ command: String) -> Bool {
        let lowered = command.lowercased()
        guard let first = lowered.split(separator: " ").first.map(String.init) else { return false }
        return first == "opencode" || first.hasSuffix("/opencode")
    }

    private func isHermes(_ command: String) -> Bool {
        let lowered = command.lowercased()
        return lowered.contains("hermes_cli") || lowered.contains("slash_worker")
            || lowered.contains("/hermes.app/contents/macos/hermes")
            || lowered.contains("hermes-agent")
    }

    private func workingDirectory(from lsof: String) -> String? {
        let lines = lsof.split(whereSeparator: \.isNewline).map(String.init)
        for i in lines.indices where lines[i] == "fcwd" && lines.indices.contains(i + 1) {
            let next = lines[i + 1]
            guard next.first == "n" else { continue }
            let v = String(next.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasPrefix("/") { return v }
        }
        return nil
    }

    private func paths(in lsof: String, containing fragment: String) -> [String] {
        lsof.split(whereSeparator: \.isNewline).compactMap {
            guard $0.first == "n" else { return nil }
            let v = String($0.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return v.contains(fragment) && v.hasSuffix(".jsonl") ? v : nil
        }
    }

    private func bestClaudeTranscript(in lsof: String, cwd: String?) -> String? {
        let all = paths(in: lsof, containing: "/.claude/projects/")
        // a claude process can hold several project transcripts open; prefer
        // the one whose encoded project dir matches the process cwd
        if all.count > 1, let cwd {
            let encoded = cwd.replacingOccurrences(of: "/", with: "-")
            if let preferred = all.first(where: { $0.contains(encoded) }) { return preferred }
        }
        return all.first
    }

    private func bestCodexTranscript(in lsof: String) -> String? {
        // rollout filenames embed a timestamp, so the max name is the newest
        paths(in: lsof, containing: "/.codex/sessions/").max {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                < URL(fileURLWithPath: $1).deletingPathExtension().lastPathComponent
        }
    }

    private func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            group.leave()
        }
        guard group.wait(timeout: .now() + timeout) == .success else { p.terminate(); return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Session scanning

final class SessionScanner {
    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// `live` = transcript paths held open by a running agent process;
    /// `claudeCwdCounts` = encoded-project-dir → number of claude processes
    /// with that cwd (the fallback when claude exposes no open transcript).
    /// Together they are the sole source of truth for isRunning.
    func scan(live: Set<String>, claudeCwdCounts: [String: Int], opencodeCwds: Set<String>) -> [AgentSession] {
        let recent: (AgentSession) -> Bool = { $0.isLive || Date().timeIntervalSince($0.lastModified) < 6 * 3600 }
        let hermesLive = live.contains("hermes")
        var sessions = scanClaude(live: live, cwdCounts: claudeCwdCounts).filter(recent)
            + groupCodex(scanCodex(live: live).filter(recent))
            + scanOpenCode(liveCwds: opencodeCwds).filter(recent)
            + scanHermes(isLive: hermesLive).filter(recent)
        sessions.sort { $0.effectiveLastModified > $1.effectiveLastModified }
        return sessions
    }

    /// Fold Codex subagent rollouts under their root thread as children.
    private func groupCodex(_ nodes: [AgentSession]) -> [AgentSession] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.threadID, $0) })
        func rootKey(_ n: AgentSession) -> String {
            var cur = n, hops = 0
            while let p = cur.parentID, hops < 10 {
                guard let parent = byID[p] else { return p }  // parent aged out: group under its id anyway
                cur = parent; hops += 1
            }
            return cur.threadID
        }
        var groups: [String: [AgentSession]] = [:]
        for n in nodes { groups[rootKey(n), default: []].append(n) }
        var out: [AgentSession] = []
        for (key, members) in groups {
            var parent = byID[key] ?? members.sorted { $0.lastModified > $1.lastModified }[0]
            var kids = members.filter { $0.threadID != parent.threadID }
            kids.sort { $0.lastModified > $1.lastModified }
            // One codex process serves the whole thread group but holds only
            // its most recently opened rollout fd — so liveness observed on
            // any member means the shared process is alive for all of them.
            if parent.isLive || kids.contains(where: { $0.isLive }) {
                parent.isLive = true
                for i in kids.indices { kids[i].isLive = true }
            }
            parent.children = kids
            out.append(parent)
        }
        return out
    }

    private func scanClaude(live: Set<String>, cwdCounts: [String: Int]) -> [AgentSession] {
        var out: [AgentSession] = []
        let root = home.appendingPathComponent(".claude/projects")
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return out }
        for proj in projects {
            guard let files = try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            var dated: [(URL, Date)] = files.compactMap { f in
                guard f.pathExtension == "jsonl",
                      let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                return (f, m)
            }
            dated.sort { $0.1 > $1.1 }
            // cwd fallback: N claude processes in this project dir make its N
            // newest transcripts live (claude keeps no transcript fd open)
            let liveByCwd = cwdCounts[proj.lastPathComponent] ?? 0
            for (idx, (f, mtime)) in dated.enumerated() {
                let projName = proj.lastPathComponent.split(separator: "-").last.map(String.init) ?? proj.lastPathComponent
                let info = tailInfo(of: f)
                var sess = AgentSession(id: f.path, kind: .claude, title: projName,
                                        snippet: info.snippet, model: info.model, lastModified: mtime)
                sess.prompt = info.prompt
                sess.lastActivity = info.activity
                sess.isLive = live.contains(f.path) || idx < liveByCwd
                sess.children = claudeSubagents(sessionFile: f, parentLive: sess.isLive)
                out.append(sess)
            }
        }
        return out
    }

    private func scanCodex(live: Set<String>) -> [AgentSession] {
        var out: [AgentSession] = []
        let root = home.appendingPathComponent(".codex/sessions")
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return out }
        let codexDesktopLive = live.contains("codex-desktop")
        for case let f as URL in en where f.pathExtension == "jsonl" {
            guard let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            // Skip old files early to avoid reading them
            if Date().timeIntervalSince(mtime) > 6 * 3600 { continue }
            let meta = codexMeta(of: f)
            let info = tailInfo(of: f)
            var sess = AgentSession(id: f.path, kind: .codex, title: meta.title,
                                    snippet: info.snippet, model: info.model, lastModified: mtime)
            sess.prompt = info.prompt
            sess.busyOverride = info.taskActive ?? false
            // ponytail: desktop sentinel marks all Codex sessions live; single-session assumption
            sess.isLive = live.contains(f.path) || codexDesktopLive
            sess.threadID = meta.id
            sess.parentID = meta.parentID
            sess.nickname = meta.nickname
            out.append(sess)
        }
        return out
    }

    /// OpenCode stores sessions in SQLite at ~/.local/share/opencode/opencode.db.
    /// Liveness: cwd-based — sessions whose directory matches a live process cwd.
    private func scanOpenCode(liveCwds: Set<String>) -> [AgentSession] {
        let dbPath = home.appendingPathComponent(".local/share/opencode/opencode.db").path
        guard fm.fileExists(atPath: dbPath) else { return [] }
        // ponytail: shell out to sqlite3 — no SQLite C library dependency
        let sql = #"""
        SELECT s.id, s.title, s.model, s.time_updated, s.directory
        FROM session s
        WHERE s.time_updated > \#(Int64((Date().timeIntervalSince1970 - 6 * 3600) * 1000))
        ORDER BY s.time_updated DESC
        LIMIT 20;
        """#
        guard let rows = run("/usr/bin/sqlite3", [dbPath, sql], timeout: 1.0) else { return [] }
        var out: [AgentSession] = []
        for line in rows.split(separator: "\n") {
            let cols = line.split(separator: "|", omittingEmptySubsequences: false)
            guard cols.count >= 5 else { continue }
            let id = String(cols[0]), title = String(cols[1])
            let modelJSON = String(cols[2]), timeUpdated = String(cols[3])
            let dir = String(cols[4])
            guard let ts = Double(timeUpdated) else { continue }
            let mtime = Date(timeIntervalSince1970: ts / 1000)
            // Extract model name from JSON: {"id":"provider/model",...}
            let model = modelJSON.range(of: #""id":"([^"]+)""#, options: .regularExpression)
                .map { String(modelJSON[$0].dropFirst(6).dropLast(1)) }
                ?? "opencode"
            // Get snippet and prompt from the most recent part entry
            let info = opencodeTailInfo(sessionID: id)
            var sess = AgentSession(id: id, kind: .opencode, title: title,
                                    snippet: info.snippet, model: model, lastModified: mtime)
            sess.prompt = info.prompt
            sess.lastActivity = info.activity
            sess.isLive = liveCwds.contains(dir)
            out.append(sess)
        }
        return out
    }

    private func opencodeTailInfo(sessionID: String) -> (snippet: String, prompt: String, activity: Date?) {
        let dbPath = home.appendingPathComponent(".local/share/opencode/opencode.db").path
        // Last assistant text as snippet
        let snippetSQL = """
        SELECT p.data FROM part p JOIN message m ON p.message_id = m.id
        WHERE p.session_id = '\(sessionID)' AND json_extract(m.data, '$.role') = 'assistant'
        AND json_extract(p.data, '$.type') = 'text'
        ORDER BY p.time_created DESC LIMIT 1;
        """
        var snippet = ""
        if let raw = run("/usr/bin/sqlite3", [dbPath, snippetSQL], timeout: 0.5)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if let r = raw.range(of: #""text":"([^"]*)""#, options: .regularExpression) {
                var t = String(raw[r].dropFirst(8).dropLast(1))
                t = t.replacingOccurrences(of: "\\n", with: " ")
                if t.count > 90 { t = String(t.prefix(90)) + "…" }
                snippet = t
            }
        }
        // Last user text as prompt
        let promptSQL = """
        SELECT p.data FROM part p JOIN message m ON p.message_id = m.id
        WHERE p.session_id = '\(sessionID)' AND json_extract(m.data, '$.role') = 'user'
        AND json_extract(p.data, '$.type') = 'text'
        ORDER BY p.time_created DESC LIMIT 1;
        """
        var prompt = ""
        if let raw = run("/usr/bin/sqlite3", [dbPath, promptSQL], timeout: 0.5)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if let r = raw.range(of: #""text":"([^"]*)""#, options: .regularExpression) {
                var t = String(raw[r].dropFirst(8).dropLast(1))
                t = t.replacingOccurrences(of: "\\n", with: " ")
                if t.count > 90 { t = String(t.prefix(90)) + "…" }
                prompt = t
            }
        }
        // Activity: last user or assistant message time
        let activitySQL = """
        SELECT json_extract(m.data, '$.time.created') FROM message m
        WHERE m.session_id = '\(sessionID)' AND json_extract(m.data, '$.role') IN ('user', 'assistant')
        ORDER BY m.time_created DESC LIMIT 1;
        """
        var activity: Date?
        if let raw = run("/usr/bin/sqlite3", [dbPath, activitySQL], timeout: 0.5)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let ts = Double(raw) {
            activity = Date(timeIntervalSince1970: ts / 1000)
        }
        return (snippet, prompt, activity)
    }

    /// Hermes Agent stores sessions in SQLite at ~/.hermes/state.db.
    /// Liveness: sentinel-based — if any hermes process is alive, active sessions are live.
    private func scanHermes(isLive: Bool) -> [AgentSession] {
        guard isLive else { return [] }
        let dbPath = home.appendingPathComponent(".hermes/state.db").path
        guard fm.fileExists(atPath: dbPath) else { return [] }
        // Active sessions: ended_at IS NULL, started in last 6h
        let sql = #"""
        SELECT s.id, s.title, s.model, s.started_at, MAX(m.timestamp) AS last_activity
        FROM sessions s
        LEFT JOIN messages m ON m.session_id = s.id
        WHERE s.ended_at IS NULL AND s.started_at > \#(Date().timeIntervalSince1970 - 6 * 3600)
        GROUP BY s.id
        ORDER BY COALESCE(last_activity, s.started_at) DESC
        LIMIT 10;
        """#
        guard let rows = run("/usr/bin/sqlite3", [dbPath, sql], timeout: 1.0) else { return [] }
        var out: [AgentSession] = []
        for line in rows.split(separator: "\n") {
            let cols = line.split(separator: "|", omittingEmptySubsequences: false)
            guard cols.count >= 4 else { continue }
            let id = String(cols[0]), title = String(cols[1])
            let model = String(cols[2]), started = String(cols[3])
            guard let ts = Double(started) else { continue }
            let mtime = Date(timeIntervalSince1970: ts)
            // ponytail: no snippet extraction from messages table; use session title
            var sess = AgentSession(id: id, kind: .hermes, title: title,
                                    snippet: "", model: model, lastModified: mtime)
            sess.prompt = title
            if cols.count >= 5, let activity = Double(cols[4]) {
                sess.lastActivity = Date(timeIntervalSince1970: activity)
            }
            sess.isLive = true
            out.append(sess)
        }
        return out
    }

    /// Claude Code subagent transcripts live in <proj>/<session-uuid>/subagents/agent-*.jsonl
    private func claudeSubagents(sessionFile f: URL, parentLive: Bool) -> [AgentSession] {
        let dir = f.deletingPathExtension().appendingPathComponent("subagents")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var kids: [AgentSession] = []
        for c in files where c.pathExtension == "jsonl" {
            guard let mtime = (try? c.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  Date().timeIntervalSince(mtime) < 6 * 3600 else { continue }
            let info = tailInfo(of: c)
            var kid = AgentSession(id: c.path, kind: .claude, title: "subagent",
                                   snippet: info.snippet, model: info.model, lastModified: mtime)
            // no nicknames here — label with the task it was given
            kid.nickname = info.prompt.isEmpty ? "subagent" : String(info.prompt.prefix(40))
            // subagents share the parent process (open-vibe-island tracks them
            // as parent metadata) — liveness inherits, busyness from writes
            kid.isLive = parentLive
            kid.lastActivity = info.activity
            kids.append(kid)
        }
        return kids.sorted { $0.lastModified > $1.lastModified }
    }

    private func codexMeta(of file: URL) -> (title: String, id: String, parentID: String?, nickname: String?) {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return ("Codex", file.path, nil, nil) }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 262_144)
        guard let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return ("Codex", file.path, nil, nil) }
        let title = ((payload["cwd"] as? String).map { ($0 as NSString).lastPathComponent }) ?? "Codex"
        let id = (payload["id"] as? String) ?? file.path
        let parentID = payload["parent_thread_id"] as? String
        let nickname = (((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["agent_nickname"] as? String
        return (title, id, parentID, nickname)
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Read the tail of a jsonl transcript: last human-readable text + model
    /// name + timestamp of the last conversational (user/assistant) entry.
    private func tailInfo(of file: URL) -> (snippet: String, model: String, prompt: String, activity: Date?, taskActive: Bool?) {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return ("", "", "", nil, nil) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let readLen: UInt64 = min(size, 131_072)
        try? fh.seek(toOffset: size - readLen)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return ("", "", "", nil, nil) }
        var snippet = "", model = "", prompt = ""
        var activity: Date?
        var taskActive: Bool?
        for line in text.split(separator: "\n").reversed() {
            if model.isEmpty, let r = line.range(of: #""model":"([^"]+)""#, options: .regularExpression) {
                model = String(line[r].dropFirst(9).dropLast(1))
                model = model.replacingOccurrences(of: "claude-", with: "")
            }
            if snippet.isEmpty || prompt.isEmpty || activity == nil || taskActive == nil,
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                if snippet.isEmpty, let s = extractText(obj) { snippet = s }
                if prompt.isEmpty, let p = extractUserPrompt(obj) { prompt = p }
                // "system" entries (away_summary, compaction notes…) are
                // housekeeping, not activity
                if activity == nil, let ty = obj["type"] as? String,
                   ty == "user" || ty == "assistant",
                   let ts = obj["timestamp"] as? String {
                    activity = Self.isoParser.date(from: ts)
                }
                if taskActive == nil,
                   let payload = obj["payload"] as? [String: Any],
                   let type = payload["type"] as? String {
                    if type == "task_started" { taskActive = true }
                    if type == "task_complete" { taskActive = false }
                }
            }
            if !snippet.isEmpty && !model.isEmpty && !prompt.isEmpty && activity != nil && taskActive != nil { break }
        }
        if model.isEmpty, size > readLen {
            // model can appear only early in long transcripts — check the head too
            try? fh.seek(toOffset: 0)
            if let head = try? fh.read(upToCount: 65_536),
               let headText = String(data: head, encoding: .utf8),
               let r = headText.range(of: #""model":"([^"]+)""#, options: .regularExpression) {
                model = String(headText[r].dropFirst(9).dropLast(1))
                    .replacingOccurrences(of: "claude-", with: "")
            }
        }
        return (snippet, model, prompt, activity, taskActive)
    }

    /// The user's own message, if this line is one.
    private func extractUserPrompt(_ obj: [String: Any]) -> String? {
        // Codex: {"payload":{"type":"user_message","message":"..."}}
        if let payload = obj["payload"] as? [String: Any],
           payload["type"] as? String == "user_message",
           let m = payload["message"] as? String { return clean(m) }
        // Claude: {"type":"user","message":{"content":"..." | [{"type":"text","text":...}]}}
        if obj["type"] as? String == "user", let msg = obj["message"] as? [String: Any] {
            if let c = msg["content"] as? String { return clean(c) }
            if let arr = msg["content"] as? [[String: Any]] {
                for part in arr where part["type"] as? String == "text" {
                    if let t = part["text"] as? String { return clean(t) }
                }
            }
        }
        return nil
    }

    private func extractText(_ obj: [String: Any]) -> String? {
        // Claude: {"message": {"content": [{"type":"text","text":...}] | "..."}}
        var content: Any? = nil
        if let msg = obj["message"] as? [String: Any] { content = msg["content"] }
        // Codex: {"payload": {"content": [...]}} or nested message
        if content == nil, let payload = obj["payload"] as? [String: Any] {
            content = payload["content"] ?? (payload["message"] as? [String: Any])?["content"]
        }
        if let s = content as? String { return clean(s) }
        if let arr = content as? [[String: Any]] {
            for part in arr.reversed() {
                if let t = part["text"] as? String { return clean(t) }
            }
        }
        return nil
    }

    private func clean(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("{") { return nil }  // skip system-reminder / tool json
        t = t.replacingOccurrences(of: "\n", with: " ")
        if t.count > 90 { t = String(t.prefix(90)) + "…" }
        return t
    }

    private func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            group.leave()
        }
        guard group.wait(timeout: .now() + timeout) == .success else { p.terminate(); return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Dither theme views

/// Row icon: mini mascot / Codex pet while running, green pixel checkmark when done.
final class DitherIconView: NSView {
    var running = false
    var idle = false  // alive but quiet: dim, static
    var kind: AgentKind = .claude
    var color: NSColor = .systemBlue  // kept for tint fallbacks
    var t: CGFloat = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 16) }

    static let checkmark: [(Int, Int)] = [
        (6, 1), (5, 2), (4, 3), (0, 3), (1, 4), (3, 4), (2, 5)
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if !running && !idle {
            // done: green pixel checkmark
            let cell: CGFloat = 2.2
            for (x, y) in Self.checkmark {
                ctx.setFillColor(NSColor.systemGreen.cgColor)
                ctx.fill(CGRect(x: 1 + CGFloat(x) * cell, y: 1 + CGFloat(7 - y) * cell,
                                width: cell - 0.4, height: cell - 0.4))
            }
            return
        }
        let alpha: CGFloat = idle ? 0.4 : 1.0
        if kind == .hermes, let icon = IndicatorView.hermesIcon {
            let base: CGFloat = 16
            let pulse: CGFloat = running ? sin(t * 8) * 1.0 : 0
            let side = base + pulse
            let x = 1 + (base - side) / 2
            let y = running ? sin(t * 8) * 1.5 : 0
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(in: NSRect(x: x, y: y, width: side, height: side), from: .zero, operation: .sourceOver, fraction: alpha)
            return
        }
        if kind == .codex, let sprite = IndicatorView.codexSprite {
            let fw: CGFloat = 192, fh: CGFloat = 208
            let idx = idle ? 0 : Int(t / 0.12) % 8
            let src = NSRect(x: CGFloat(idx) * fw, y: 1872 - 2 * fh, width: fw, height: fh)
            NSGraphicsContext.current?.imageInterpolation = .none
            sprite.draw(in: NSRect(x: 1, y: 0, width: 16 * fw / fh, height: 16),
                        from: src, operation: .sourceOver, fraction: alpha)
            return
        }
        // mini Claude mascot walking, with a visible bob (static + dim when idle)
        let subW: CGFloat = 1.0, subH: CGFloat = 2.0
        let walk = idle ? 0 : Int(t * 2.5)
        let frame = IndicatorView.mascotFrames[walk % 2]
        let rows = frame.count * 2
        let y0 = CGFloat(rows) * subH + 1 + (walk % 2 == 0 ? 0 : 1.5)
        for (j, line) in frame.enumerated() {
            for (i, ch) in line.enumerated() {
                guard let q = IndicatorView.quadrants[ch] else { continue }
                let cells = [(q.0, 0, 0), (q.1, 1, 0), (q.2, 0, 1), (q.3, 1, 1)]
                for (on, qx, qy) in cells where on {
                    ctx.setFillColor(IndicatorView.claudeOrange.withAlphaComponent(alpha).cgColor)
                    ctx.fill(CGRect(x: CGFloat(i * 2 + qx) * subW,
                                    y: y0 - CGFloat(j * 2 + qy + 1) * subH,
                                    width: subW - 0.2, height: subH - 0.3))
                }
            }
        }
    }
}

/// A sparse row of gray pixels — the dithered stand-in for a separator line.
final class DitherSeparator: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cell: CGFloat = 2
        var x: CGFloat = 0
        var seed: UInt64 = 0x9E3779B9
        while x < bounds.width {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = CGFloat(seed >> 33 & 0xFFFF) / 65535
            if r > 0.55 {
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.06 + 0.10 * r).cgColor)
                ctx.fill(CGRect(x: x, y: 1, width: cell - 0.4, height: cell - 0.4))
            }
            x += cell
        }
    }
}

// MARK: - Session list popover

final class SessionListController: NSViewController {
    var sessions: [AgentSession] = [] { didSet { rebuild() } }
    var onLayoutChange: (() -> Void)?
    private let stack = NSStackView()
    private var icons: [DitherIconView] = []
    private var animTimer: Timer?
    private var expandedIDs = Set<String>()

    override func loadView() {
        let v = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        view = v
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        icons.removeAll()
        if sessions.isEmpty {
            stack.addArrangedSubview(label("No recent agent sessions", size: 12, color: .secondaryLabelColor, bold: false))
            return
        }
        for (i, s) in sessions.prefix(6).enumerated() {
            if i > 0 {
                let sep = DitherSeparator()
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            stack.addArrangedSubview(row(for: s))
            if !s.children.isEmpty {
                let open = expandedIDs.contains(s.id)
                let btn = NSButton(title: "\(open ? "▾" : "▸") \(s.children.count) subagent\(s.children.count == 1 ? "" : "s")",
                                   target: self, action: #selector(toggleChildren(_:)))
                btn.isBordered = false
                btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
                btn.contentTintColor = .systemBlue
                btn.identifier = NSUserInterfaceItemIdentifier(s.id)
                let wrap = NSStackView(views: [btn])
                wrap.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)
                stack.addArrangedSubview(wrap)
                if open {
                    for child in s.children.prefix(8) {
                        stack.addArrangedSubview(childRow(for: child))
                    }
                }
            }
        }
        if animTimer == nil {
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self else { return }
                for icon in self.icons { icon.t += 0.12 }
            }
        }
    }

    @objc private func toggleChildren(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
        rebuild()
        onLayoutChange?()
    }

    private func childRow(for s: AgentSession) -> NSView {
        let icon = DitherIconView()
        icon.running = s.isBusy
        icon.idle = s.isLive && !s.isBusy
        icon.kind = s.kind
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        icons.append(icon)
        let name = label(s.nickname ?? (s.title.isEmpty ? s.kind.rawValue : s.title), size: 11, color: .secondaryLabelColor, bold: true)
        let tag = label("\(s.model.isEmpty ? s.kind.rawValue : s.model) · \(relative(s.lastModified))", size: 9,
                        color: (s.isBusy ? NSColor.systemBlue : s.isLive ? .secondaryLabelColor : .systemGreen).withAlphaComponent(0.6), bold: false)
        tag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = NSStackView(views: [icon, name, NSView(), tag])
        top.orientation = .horizontal
        top.translatesAutoresizingMaskIntoConstraints = false
        var views: [NSView] = [top]
        if !s.snippet.isEmpty {
            let snip = label(s.snippet, size: 11, color: .secondaryLabelColor, bold: false)
            snip.maximumNumberOfLines = 1
            snip.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
            views.append(snip)
        }
        let col = NSStackView(views: views)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        col.edgeInsets = NSEdgeInsets(top: 2, left: 28, bottom: 2, right: 4)
        top.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -32).isActive = true
        return col
    }

    var contentHeight: CGFloat {
        stack.fittingSize.height
    }

    private func row(for s: AgentSession) -> NSView {
        let icon = DitherIconView()
        icon.running = s.anyBusy
        icon.idle = s.anyLive && !s.anyBusy
        icon.kind = s.kind
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        icons.append(icon)
        let title = label(s.kind.rawValue, size: 12, color: .labelColor, bold: true)
        let tag = label("\(s.model.isEmpty ? s.title : s.model) · \(relative(s.lastModified))", size: 10,
                        color: (s.anyBusy ? NSColor.systemBlue : s.anyLive ? .secondaryLabelColor : .systemGreen).withAlphaComponent(0.75), bold: false)
        tag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let top = NSStackView(views: [icon, title, NSView(), tag])
        top.orientation = .horizontal
        top.translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = [top]
        let line = s.prompt.isEmpty ? s.snippet : "You: " + s.prompt
        if !line.isEmpty {
            let snippet = label(line, size: 11, color: .secondaryLabelColor, bold: false)
            snippet.maximumNumberOfLines = 1
            snippet.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true
            views.append(snippet)
        }
        let col = NSStackView(views: views)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        col.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        top.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -8).isActive = true
        return col
    }

    private func label(_ text: String, size: CGFloat, color: NSColor, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        // Truncate rather than force the window wider than its frame
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

// MARK: - Notch window content

/// Indicator content: branded pixel animations for whichever agents are running.
enum AgentGlyphState { case inactive, running, done }

final class IndicatorView: NSView {
    var claudeState: AgentGlyphState = .inactive { didSet { needsDisplay = true } }
    var codexState: AgentGlyphState = .inactive { didSet { needsDisplay = true } }
    var opencodeState: AgentGlyphState = .inactive { didSet { needsDisplay = true } }
    var hermesState: AgentGlyphState = .inactive { didSet { needsDisplay = true } }
    var t: CGFloat = 0 { didSet { needsDisplay = true } }

    static let claudeOrange = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)  // Anthropic coral
    static let codexTeal = NSColor(red: 0.06, green: 0.64, blue: 0.50, alpha: 1)     // OpenAI teal
    static let opencodePurple = NSColor(red: 0.55, green: 0.30, blue: 0.85, alpha: 1) // OpenCode purple
    static let hermesAmber = NSColor(red: 0.95, green: 0.65, blue: 0.15, alpha: 1)    // Hermes amber/gold

    // The Claude Code launch-banner mascot, drawn from its real block characters.
    // Two frames: the feet alternate so it walks.
    static let mascotFrames: [[String]] = [
        [" ▐▛███▜▌ ",
         "▝▜█████▛▘",
         "  ▘▘ ▝▝  "],
        [" ▐▛███▜▌ ",
         "▝▜█████▛▘",
         "  ▝▝ ▘▘  "],
    ]
    // quadrant bits: (upper-left, upper-right, lower-left, lower-right)
    static let quadrants: [Character: (Bool, Bool, Bool, Bool)] = [
        "█": (true, true, true, true),
        "▐": (false, true, false, true),
        "▌": (true, false, true, false),
        "▛": (true, true, true, false),
        "▜": (true, true, false, true),
        "▙": (true, false, true, true),
        "▟": (false, true, true, true),
        "▘": (true, false, false, false),
        "▝": (false, true, false, false),
        "▖": (false, false, true, false),
        "▗": (false, false, false, true),
        " ": (false, false, false, false),
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cy = bounds.midY
        var x = bounds.maxX - 6  // right-aligned toward the notch
        // each agent keeps its own slot: mascot while running, green blob when
        // freshly done (cleared once you revisit the terminal)
        switch claudeState {
        case .running: x = drawCrab(ctx, right: x, cy: cy) - 6
        case .done: drawGreenBlob(ctx, right: x, cy: cy); x -= 24
        case .inactive: break
        }
        switch codexState {
        case .running: x = drawCodexPet(ctx, right: x, cy: cy) - 6
        case .done: drawGreenBlob(ctx, right: x, cy: cy); x -= 24
        case .inactive: break
        }
        switch opencodeState {
        case .running: x = drawRing(ctx, right: x, cy: cy, color: Self.opencodePurple) - 6
        case .done: drawGreenBlob(ctx, right: x, cy: cy); x -= 24
        case .inactive: break
        }
        switch hermesState {
        case .running: x = drawHermesIcon(ctx, right: x, cy: cy) - 6
        case .done: drawGreenBlob(ctx, right: x, cy: cy); x -= 24
        case .inactive: break
        }
    }

    private func drawGreenBlob(_ ctx: CGContext, right: CGFloat, cy: CGFloat) {
        let cell: CGFloat = 2.5, grid = 7
        let c = CGFloat(grid) / 2
        let step = Int(t * 2)
        let x0 = right - CGFloat(grid) * cell
        for i in 0..<grid {
            for j in 0..<grid {
                let dx = CGFloat(i) + 0.5 - c, dy = CGFloat(j) + 0.5 - c
                let dist = sqrt(dx * dx + dy * dy)
                let n = sin(CGFloat(i * 374761 + j * 668265 + step * 982451) * 0.0001) * 43758.5453
                let r = n - n.rounded(.down)
                guard r > 0.1 + dist / c * 0.8 else { continue }
                ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.5 + 0.5 * r).cgColor)
                ctx.fill(CGRect(x: x0 + CGFloat(i) * cell, y: cy - CGFloat(grid) * cell / 2 + CGFloat(j) * cell,
                                width: cell - 0.5, height: cell - 0.5))
            }
        }
    }

    private static let hermesAppPaths = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/hermes-agent/apps/desktop/release/mac-arm64/Hermes.app").path,
        "/Applications/Hermes.app"
    ]
    static var hermesIcon: NSImage? = {
        guard let path = hermesAppPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }()

    private func drawHermesIcon(_ ctx: CGContext, right: CGFloat, cy: CGFloat) -> CGFloat {
        guard let icon = Self.hermesIcon else {
            return drawRing(ctx, right: right, cy: cy, color: Self.hermesAmber)
        }
        let base: CGFloat = 22
        let pulse: CGFloat = sin(t * 8) * 1.5
        let side = base + pulse
        let bob: CGFloat = sin(t * 8) * 2
        let dest = NSRect(x: right - side, y: cy - side / 2 + bob, width: side, height: side)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
        return dest.minX
    }

    /// Returns the left edge of what was drawn.
    private func drawCrab(_ ctx: CGContext, right: CGFloat, cy: CGFloat) -> CGFloat {
        // terminal cells are ~2x taller than wide — keep that aspect or he squishes
        let subW: CGFloat = 1.6, subH: CGFloat = 3.2
        let walk = Int(t * 2.5)
        let frame = Self.mascotFrames[walk % 2]
        let cols = frame[0].count * 2, rows = frame.count * 2
        let x0 = right - CGFloat(cols) * subW
        let bob: CGFloat = (walk % 2 == 0) ? -0.5 : 0.5  // little bounce, symmetric around center
        let y0 = cy + CGFloat(rows) * subH / 2 + bob - 2  // feet row is sparse; nudge down so the body reads centered
        let step = Int(t * 3)
        for (j, line) in frame.enumerated() {
            for (i, ch) in line.enumerated() {
                guard let q = Self.quadrants[ch] else { continue }
                let cells = [(q.0, 0, 0), (q.1, 1, 0), (q.2, 0, 1), (q.3, 1, 1)]
                for (on, qx, qy) in cells where on {
                    let n = sin(CGFloat(i * 374761 + j * 668265 + (qx + qy * 2) * 97 + step * 982451) * 0.0001) * 43758.5453
                    let r = n - n.rounded(.down)
                    // feet stay solid; body shimmers gently
                    let isFeet = j == frame.count - 1
                    let alpha = isFeet ? 1.0 : 0.8 + 0.2 * r
                    ctx.setFillColor(Self.claudeOrange.withAlphaComponent(alpha).cgColor)
                    ctx.fill(CGRect(x: x0 + CGFloat(i * 2 + qx) * subW,
                                    y: y0 - CGFloat(j * 2 + qy + 1) * subH,
                                    width: subW - 0.3, height: subH - 0.4))
                }
            }
        }
        return x0
    }

    // Official Codex pet spritesheets (8 cols x 9 rows, 192x208 frames);
    // row 1 is the "running-right" animation, 8 frames @ 120 ms.
    // The pet is chosen by ~/.config/agent-notch/pet (codex, dewey, fireball,
    // rocky, seedy, stacky, bsod, null-signal).
    static var currentPetID = "codex"
    private static var spriteCache: [String: NSImage] = [:]
    static var codexSprite: NSImage? {
        if let img = spriteCache[currentPetID] { return img }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GitHub/agent-notch/pets/pet-\(currentPetID).webp").path
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        spriteCache[currentPetID] = img
        return img
    }
    static func refreshPetChoice() {
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-notch/pet")
        if let id = try? String(contentsOf: cfg, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            currentPetID = id
        }
    }

    private func drawCodexPet(_ ctx: CGContext, right: CGFloat, cy: CGFloat) -> CGFloat {
        guard let sprite = Self.codexSprite else {
            return drawRing(ctx, right: right, cy: cy, color: Self.codexTeal)
        }
        let fw: CGFloat = 192, fh: CGFloat = 208
        let idx = Int(t / 0.12) % 8
        let src = NSRect(x: CGFloat(idx) * fw, y: 1872 - 2 * fh, width: fw, height: fh)
        let h: CGFloat = 26, w = h * fw / fh
        let dest = NSRect(x: right - w, y: cy - h / 2, width: w, height: h)
        NSGraphicsContext.current?.imageInterpolation = .none  // keep the pixel art crisp
        sprite.draw(in: dest, from: src, operation: .sourceOver, fraction: 1)
        return dest.minX
    }

    /// Returns the left edge of what was drawn.
    private func drawRing(_ ctx: CGContext, right: CGFloat, cy: CGFloat, color: NSColor) -> CGFloat {
        let cell: CGFloat = 2.5, grid = 9
        let x0 = right - CGFloat(grid) * cell
        let y0 = cy - CGFloat(grid) * cell / 2
        let c = CGFloat(grid) / 2
        let phase = t * 1.4
        let step = Int(t * 3)
        for i in 0..<grid {
            for j in 0..<grid {
                let dx = CGFloat(i) + 0.5 - c
                let dy = CGFloat(j) + 0.5 - c
                let dist = sqrt(dx * dx + dy * dy)
                guard dist > c - 2.4, dist < c else { continue }
                var angle = atan2(dy, dx) - phase
                angle = angle - (angle / (2 * .pi)).rounded(.down) * 2 * .pi
                let intensity = 1 - angle / (2 * .pi)
                let n = sin(CGFloat(i * 374761 + j * 668265 + step * 982451) * 0.0001) * 43758.5453
                let r = n - n.rounded(.down)
                let a = intensity * intensity * (0.55 + 0.45 * r)
                guard a > 0.08 else { continue }
                ctx.setFillColor(color.withAlphaComponent(a).cgColor)
                ctx.fill(CGRect(x: x0 + CGFloat(i) * cell, y: y0 + CGFloat(j) * cell,
                                width: cell - 0.5, height: cell - 0.5))
            }
        }
        return x0
    }
}

final class NotchView: NSView {
    var expanded = false { didSet { needsDisplay = true } }
    var barHeight: CGFloat = 32
    var onCollapse: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { onCollapse?() }
    override func rightMouseUp(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Agent Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        if expanded {
            // Black panel with rounded bottom corners, only when open
            let r: CGFloat = 16
            let path = NSBezierPath()
            path.move(to: NSPoint(x: b.minX, y: b.maxY))
            path.line(to: NSPoint(x: b.minX, y: b.minY + r))
            path.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.minY + r), radius: r, startAngle: 180, endAngle: 270, clockwise: false)
            path.line(to: NSPoint(x: b.maxX - r, y: b.minY))
            path.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.minY + r), radius: r, startAngle: 270, endAngle: 0, clockwise: false)
            path.line(to: NSPoint(x: b.maxX, y: b.maxY))
            path.close()
            NSColor.black.setFill()
            path.fill()
            return  // no spinner while the panel is open
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var indicatorWindow: NSWindow!
    private let notchView = NotchView()
    private let indicatorView = IndicatorView()
    private let scanner = SessionScanner()
    private let discovery = ProcessDiscovery()
    private let scanQueue = DispatchQueue(label: "agent-notch.scan", qos: .utility)
    // open-vibe-island removal rule: a transcript's process must be missing
    // for 2 consecutive polls (~6 s) before its session stops being live
    private var missCounts: [String: Int] = [:]
    private let listController = SessionListController()
    private var frame = 0
    private var claudeWasLive = false
    private var codexWasLive = false
    private var opencodeWasLive = false
    private var hermesWasLive = false
    private var claudeState: AgentGlyphState = .inactive
    private var codexState: AgentGlyphState = .inactive
    private var opencodeState: AgentGlyphState = .inactive
    private var hermesState: AgentGlyphState = .inactive
    private var expanded = false

    // Geometry
    private var screen: NSScreen { NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main! }
    private var notchWidth: CGFloat {
        let s = screen
        if #available(macOS 12.0, *), s.safeAreaInsets.top > 0,
           let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            return s.frame.width - left.width - right.width
        }
        return 180  // no physical notch: fake pill
    }
    private var barHeight: CGFloat {
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        return 30
    }
    private let sidePad: CGFloat = 120  // indicator strip beside the notch
    private let expandedSize = NSSize(width: 480, height: 240)

    // In a fullscreen space the menu bar is hidden, so the bar can own the whole top edge
    private var isFullscreenSpace: Bool {
        screen.visibleFrame.maxY >= screen.frame.maxY - 1
    }

    private func collapsedFrame() -> NSRect {
        // Always full-width: transparent and click-through, so it costs nothing,
        // and the indicator can dodge menu items anywhere along the bar
        let s = screen.frame
        return NSRect(x: s.minX, y: s.maxY - barHeight, width: s.width, height: barHeight)
    }

    /// Fixed spot just left of the notch.
    private var indicatorScreenX: CGFloat {
        let s = screen
        var notchLeftX = s.frame.midX - 90
        if #available(macOS 12.0, *), let left = s.auxiliaryTopLeftArea { notchLeftX = left.maxX }
        return notchLeftX - 36
    }
    private func expandedFrame() -> NSRect {
        let s = screen.frame
        let w = max(expandedSize.width, notchWidth + sidePad * 2)
        let h = barHeight + max(60, listController.contentHeight) + 10
        return NSRect(x: s.midX - w / 2, y: s.maxY - h, width: w, height: h)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Panel window: full-width, mouse-transparent unless expanded
        window = NSWindow(contentRect: collapsedFrame(), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)  // panel is always black
        window.contentView = notchView
        notchView.wantsLayer = true
        notchView.barHeight = barHeight

        // Indicator window: tiny, always interactive, never steals focus
        indicatorWindow = NSPanel(contentRect: indicatorScreenRect,
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        indicatorWindow.isOpaque = false
        indicatorWindow.backgroundColor = .clear
        indicatorWindow.hasShadow = false
        indicatorWindow.level = .statusBar
        indicatorWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        indicatorWindow.ignoresMouseEvents = true  // visual only — clicks are caught by the global monitor
        indicatorWindow.contentView = indicatorView

        listController.onLayoutChange = { [weak self] in
            guard let self, self.expanded else { return }
            self.window.setFrame(self.expandedFrame(), display: true)
        }
        notchView.onCollapse = { [weak self] in
            guard let self, self.expanded else { return }
            self.setExpanded(false)
        }
        // The indicator window never takes mouse input (routing to tiny borderless
        // menu-bar windows is unreliable) — a global monitor catches its clicks,
        // and also handles click-away dismissal.
        var lastToggle = ProcessInfo.processInfo.systemUptime
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            let now = ProcessInfo.processInfo.systemUptime
            if !self.expanded {
                if self.indicatorScreenRect.insetBy(dx: -4, dy: 0).contains(loc), now - lastToggle > 0.15 {
                    lastToggle = now
                    self.setExpanded(true)
                }
            } else if !self.window.frame.contains(loc) {
                self.setExpanded(false)
            }
        }
        window.orderFrontRegardless()
        indicatorWindow.orderFrontRegardless()

        // Revisiting the terminal acknowledges finished agents — green clears
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let terminals = ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
                             "net.kovidgoyal.kitty", "dev.warp.Warp-Stable", "io.alacritty"]
            if terminals.contains(app.bundleIdentifier ?? "") {
                if self.claudeState == .done { self.claudeState = .inactive }
                if self.codexState == .done { self.codexState = .inactive }
                if self.opencodeState == .done { self.opencodeState = .inactive }
                if self.hermesState == .done { self.hermesState = .inactive }
                self.render()
            }
        }

        // SIGUSR1 toggles the panel — lets tests drive it without synthetic clicks
        let sig = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        sig.setEventHandler { [weak self] in
            guard let self else { return }
            self.setExpanded(!self.expanded)
        }
        sig.resume()
        signal(SIGUSR1, SIG_IGN)
        self.sigSource = sig

        Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        rescan()
        // 3 s poll cadence, matching open-vibe-island's process discovery
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.rescan() }
    }

    /// Screen rect of the indicator — the only collapsed region that should catch clicks
    private var indicatorScreenRect: NSRect {
        NSRect(x: indicatorScreenX - 30, y: screen.frame.maxY - barHeight, width: 66, height: barHeight)
    }

    private func setExpanded(_ on: Bool) {
        guard expanded != on else { return }
        expanded = on
        // Attach the list only while expanded — its Auto Layout content would
        // otherwise force the borderless window wider than the collapsed frame.
        let listView = listController.view
        if on {
            notchView.expanded = true
            listView.translatesAutoresizingMaskIntoConstraints = false
            listView.alphaValue = 1
            notchView.addSubview(listView)
            NSLayoutConstraint.activate([
                listView.topAnchor.constraint(equalTo: notchView.topAnchor, constant: barHeight + 4),
                listView.leadingAnchor.constraint(equalTo: notchView.leadingAnchor, constant: 8),
                listView.trailingAnchor.constraint(equalTo: notchView.trailingAnchor, constant: -8),
            ])
        }
        // Never animate the window frame — macOS interpolates it unreliably.
        // Resize instantly while invisible and animate the content layer instead
        // (the technique used by boring.notch / NotchNook).
        if on {
            window.ignoresMouseEvents = false
            window.setFrame(expandedFrame(), display: true)
            indicatorWindow.orderOut(nil)  // spinner hides while the panel is open
            animatePanelLayer(open: true)
        } else {
            indicatorWindow.orderFrontRegardless()  // back immediately — never leave a dead zone
            window.ignoresMouseEvents = true
            animatePanelLayer(open: false) { [weak self] in
                guard let self, !self.expanded else { return }
                self.notchView.expanded = false
                listView.removeFromSuperview()
                self.window.setFrame(self.collapsedFrame(), display: true)
                self.indicatorWindow.orderFrontRegardless()
            }
        }
    }

    private var animating = false
    private var sigSource: DispatchSourceSignal?

    /// Scale + fade the content layer toward/away from the notch (top center).
    private func animatePanelLayer(open: Bool, completion: (() -> Void)? = nil) {
        guard let layer = notchView.layer else { completion?(); return }
        let b = notchView.bounds
        layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        layer.position = CGPoint(x: b.midX, y: b.maxY)
        let small = CATransform3DMakeScale(0.25, 0.06, 1)
        let from = open ? small : CATransform3DIdentity
        let to = open ? CATransform3DIdentity : small
        animating = true
        // Set model values to the end state, then animate the presentation to match
        layer.transform = to
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.animating = false
            if !open {
                // window is about to shrink; restore the layer for next time
                layer.transform = CATransform3DIdentity
            }
            completion?()
        }
        let t = CABasicAnimation(keyPath: "transform")
        t.fromValue = NSValue(caTransform3D: from)
        t.toValue = NSValue(caTransform3D: to)
        t.duration = 0.22
        t.timingFunction = CAMediaTimingFunction(name: open ? .easeOut : .easeIn)
        layer.add(t, forKey: t.keyPath)
        CATransaction.commit()
    }

    private func rescan() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            // Process discovery is the authoritative liveness signal. Keys are
            // transcript paths, or "cwd#<encoded>#<i>" for claude's cwd fallback.
            var seen = Set<String>()
            var cwdIndex: [String: Int] = [:]
            for snap in self.discovery.liveTranscripts() {
                if let path = snap.transcriptPath {
                    seen.insert(path)
                } else if snap.kind == .claude, let cwd = snap.cwd {
                    let encoded = cwd.replacingOccurrences(of: "/", with: "-")
                    let i = cwdIndex[encoded, default: 0]
                    cwdIndex[encoded] = i + 1
                    seen.insert("cwd#\(encoded)#\(i)")
                } else if snap.kind == .opencode, let cwd = snap.cwd {
                    seen.insert("opencode:\(cwd)")
                } else if snap.kind == .codex {
                    // Desktop sentinel: process alive but no open transcript
                    seen.insert("codex-desktop")
                } else if snap.kind == .hermes {
                    seen.insert("hermes")
                }
            }
            for p in seen { self.missCounts[p] = 0 }
            for (p, n) in self.missCounts where !seen.contains(p) {
                if n + 1 >= 2 { self.missCounts.removeValue(forKey: p) } else { self.missCounts[p] = n + 1 }
            }
            var live = Set<String>()
            var cwdCounts: [String: Int] = [:]
            var opencodeCwdsFinal = Set<String>()
            for key in self.missCounts.keys {
                if key.hasPrefix("cwd#") {
                    let encoded = String(key.dropFirst(4).split(separator: "#")[0])
                    cwdCounts[encoded, default: 0] += 1
                } else if key.hasPrefix("opencode:") {
                    opencodeCwdsFinal.insert(String(key.dropFirst(9)))
                } else {
                    live.insert(key)
                }
            }
            let result = self.scanner.scan(live: live, claudeCwdCounts: cwdCounts, opencodeCwds: opencodeCwdsFinal)
            DispatchQueue.main.async {
                // Track fullscreen-space changes: full-width bar when the menu bar is hidden
                if !self.expanded, !self.animating {
                    if self.window.frame != self.collapsedFrame() {
                        self.window.setFrame(self.collapsedFrame(), display: true)
                    }
                    // re-dodge menu items as the frontmost app changes
                    let r = self.indicatorScreenRect
                    if self.indicatorWindow.frame != r { self.indicatorWindow.setFrame(r, display: true) }
                }
                IndicatorView.refreshPetChoice()
                self.listController.sessions = result
                // busy → mascot; alive-but-quiet → nothing (idle, not done);
                // process exited → done blob (cleared on terminal focus)
                let claudeLive = result.contains { $0.kind == .claude && $0.anyLive }
                let claudeBusy = result.contains { $0.kind == .claude && $0.anyBusy }
                let codexLive = result.contains { $0.kind == .codex && $0.anyLive }
                let codexBusy = result.contains { $0.kind == .codex && $0.anyBusy }
                let opencodeLive = result.contains { $0.kind == .opencode && $0.anyLive }
                let opencodeBusy = result.contains { $0.kind == .opencode && $0.anyBusy }
                let hermesLive = result.contains { $0.kind == .hermes && $0.anyLive }
                let hermesBusy = result.contains { $0.kind == .hermes && $0.anyBusy }
                self.claudeState = claudeBusy ? .running
                    : claudeLive ? .inactive
                    : (self.claudeWasLive ? .done : self.claudeState)
                self.codexState = codexBusy ? .running
                    : codexLive ? .inactive
                    : (self.codexWasLive ? .done : self.codexState)
                self.opencodeState = opencodeBusy ? .running
                    : opencodeLive ? .inactive
                    : (self.opencodeWasLive ? .done : self.opencodeState)
                self.hermesState = hermesBusy ? .running
                    : hermesLive ? .inactive
                    : (self.hermesWasLive ? .done : self.hermesState)
                self.claudeWasLive = claudeLive
                self.codexWasLive = codexLive
                self.opencodeWasLive = opencodeLive
                self.hermesWasLive = hermesLive
                self.render()
            }
        }
    }

    private func tick() {
        frame += 1
        render()
    }

    private func render() {
        indicatorView.claudeState = claudeState
        indicatorView.codexState = codexState
        indicatorView.opencodeState = opencodeState
        indicatorView.hermesState = hermesState
        indicatorView.t = CGFloat(frame) * 0.12
    }
}

// Debug: `./AgentNotch --scan` prints one discovery + scan cycle and exits.
if CommandLine.arguments.contains("--scan") {
    let snaps = ProcessDiscovery().liveTranscripts()
    print("== process discovery ==")
    for s in snaps { print("\(s.kind.rawValue): path=\(s.transcriptPath ?? "nil") cwd=\(s.cwd ?? "nil")") }
    var live = Set<String>()
    var cwdCounts: [String: Int] = [:]
    var opencodeCwds = Set<String>()
    for s in snaps {
        if let p = s.transcriptPath { live.insert(p) }
        else if s.kind == .claude, let c = s.cwd { cwdCounts[c.replacingOccurrences(of: "/", with: "-"), default: 0] += 1 }
        else if s.kind == .opencode, let c = s.cwd { opencodeCwds.insert(c) }
        else if s.kind == .codex { live.insert("codex-desktop") }
        else if s.kind == .hermes { live.insert("hermes") }
    }
    print("== sessions ==")
    for s in SessionScanner().scan(live: live, claudeCwdCounts: cwdCounts, opencodeCwds: opencodeCwds) {
        print("\(s.kind.rawValue) [\(s.title)] live=\(s.isLive) busy=\(s.isBusy) mtime=\(-s.lastModified.timeIntervalSinceNow)s kids=\(s.children.count)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
