// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai's Endpoint Security client: the OS half of the storage wall.
//
// It authorizes the file operations an agent could use to read a secret or
// tamper with Kai, and hands the path(s) to the tested C engine
// (kai_path_protected). It holds no policy logic of its own.
//
// Scope of enforcement (agent attribution): we constrain processes that are a
// recognised AI agent (Claude Code / Cursor / Codex / configured) OR are
// attributable to one — by process-tree lineage AND by the responsible
// process (which catches some launchd/XPC-delegated work the parent chain
// misses). Ordinary human activity (your own shell, editors, git) is never an
// agent, so it is untouched. Kai's own code-signed binaries are exempt so the
// wall can't lock Kai out of its own config.
//
// Known limits (documented, not silently ignored): an inherited file
// descriptor opened before classification can't be revoked (ES authorizes
// open(), not read() on an existing fd); and a process fully detached to
// launchd whose responsible token does not point back to the agent is not
// attributable. Both are measured by the breadth harness.
import EndpointSecurity
import Foundation
import KaiCore
import SystemConfiguration

final class StorageClient {
    private var client: OpaquePointer?
    private var policy: OpaquePointer?            // kai_policy*
    private var mode = KAI_STORAGE_LOG
    private let lock = NSLock()
    // pid -> agent name, or "" meaning "checked, not an agent" (negative cache).
    private var agentCache: [pid_t: String] = [:]
    private var policyLoadedAt = Date.distantPast
    private var userUID: uid_t = 0
    private var userGID: gid_t = 0

    var modeName: String { mode == KAI_STORAGE_BLOCK ? "block" : "log" }

    // MARK: diagnostics (dev build only; root has no readable logs here)
    private func dlog(_ s: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + s + "\n"
        let path = "/tmp/kai-storage.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
        chmod(path, 0o666)
    }

    // MARK: lifecycle

    func start() {
        adoptConsoleUser()
        reloadPolicy(force: true)
        dlog("start: euid=\(geteuid()) adoptedUID=\(userUID) home=\(ProcessInfo.processInfo.environment["HOME"] ?? "?") mode=\(modeName) policyLoaded=\(policy != nil)")
        connect()
    }

    private func connect() {
        var c: OpaquePointer?
        let res = es_new_client(&c) { [weak self] _, msg in self?.handle(msg) }
        dlog("es_new_client result=\(res.rawValue) (success=\(res == ES_NEW_CLIENT_RESULT_SUCCESS))")
        guard res == ES_NEW_CLIENT_RESULT_SUCCESS, let c else {
            if res == ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED {
                dlog("NOT_PERMITTED — grant Kai Full Disk Access in System Settings > Privacy & Security. Retrying in 5s.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connect() }
            }
            return
        }
        client = c

        // Lifecycle (notify, no deadline) keeps the agent attribution current.
        var events: [es_event_type_t] = [
            ES_EVENT_TYPE_NOTIFY_EXEC, ES_EVENT_TYPE_NOTIFY_FORK, ES_EVENT_TYPE_NOTIFY_EXIT,
        ]
        // The file operations an agent could use against a protected path.
        // Opening a directory is AUTH_OPEN, so directory listing is covered
        // here too — there is no separate AUTH_READDIR in Endpoint Security.
        let fileEvents: [es_event_type_t] = [
            ES_EVENT_TYPE_AUTH_OPEN, ES_EVENT_TYPE_AUTH_CREATE, ES_EVENT_TYPE_AUTH_RENAME,
            ES_EVENT_TYPE_AUTH_UNLINK, ES_EVENT_TYPE_AUTH_TRUNCATE, ES_EVENT_TYPE_AUTH_LINK,
            ES_EVENT_TYPE_AUTH_CLONE, ES_EVENT_TYPE_AUTH_EXCHANGEDATA,
        ]
        // Blocking is gated at compile time; a release/notify build only
        // observes opens and can never deny.
        #if KAI_STORAGE_ENFORCE
        events += fileEvents
        #else
        events.append(ES_EVENT_TYPE_NOTIFY_OPEN)
        #endif

        let sub = es_subscribe(c, events, UInt32(events.count))
        dlog("es_subscribe result=\(sub.rawValue) events=\(events.count); enforcing in mode=\(modeName)")
    }

    private func reloadPolicy(force: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !force && Date().timeIntervalSince(policyLoadedAt) < 2 { return }
        if let p = policy { kai_policy_free(p) }
        policy = kai_policy_load(nil, nil, 0)
        mode = kai_policy_storage_mode(policy)
        policyLoadedAt = Date()
    }

    // MARK: identity helpers

    private func pidOf(_ token: audit_token_t) -> pid_t { pid_t(bitPattern: token.val.5) }
    private func pid(_ proc: UnsafeMutablePointer<es_process_t>) -> pid_t { pidOf(proc.pointee.audit_token) }

    private func esString(_ t: es_string_token_t) -> String {
        guard let d = t.data, t.length > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: d, count: t.length), as: UTF8.self)
    }

    private func path(_ f: UnsafeMutablePointer<es_file_t>) -> String { esString(f.pointee.path) }
    private func joined(_ dir: UnsafeMutablePointer<es_file_t>, _ name: es_string_token_t) -> String {
        path(dir) + "/" + esString(name)
    }

    /// Trust only a valid (non-ad-hoc) code signature from Kai's Apple team —
    /// never the executable name or an ad-hoc signing id an agent could set.
    private func isKaiOwnProcess(_ proc: UnsafeMutablePointer<es_process_t>) -> Bool {
        let flags = proc.pointee.codesigning_flags
        let csValid: UInt32 = 0x1, csAdhoc: UInt32 = 0x2
        guard (flags & csValid) != 0, (flags & csAdhoc) == 0 else { return false }
        return esString(proc.pointee.team_id) == "KD446VDTM2"
    }

    /// Is this process an agent (or attributable to one)? Cached per pid so the
    /// authorization hot path is O(1) after the first event. Consults the
    /// process-tree lineage (kai_process_agent) and the responsible-process
    /// token (catches launchd/XPC delegation the parent chain misses).
    private func agentName(_ proc: UnsafeMutablePointer<es_process_t>) -> String? {
        let p = pid(proc)
        lock.lock()
        if let cached = agentCache[p] { lock.unlock(); return cached.isEmpty ? nil : cached }
        let pol = policy
        lock.unlock()

        var name = [CChar](repeating: 0, count: 64)
        var result = ""
        if kai_process_agent(pol, p, &name, name.count, nil) == 1 {
            result = String(cString: name)
        } else {
            let rp = pidOf(proc.pointee.responsible_audit_token)
            if rp != p, rp > 1, kai_process_agent(pol, rp, &name, name.count, nil) == 1 {
                result = String(cString: name) + " (delegated)"
            }
        }
        lock.lock()
        if agentCache.count > 8192 { agentCache.removeAll() }
        agentCache[p] = result
        lock.unlock()
        return result.isEmpty ? nil : result
    }

    // MARK: event handling

    private func handle(_ msg: UnsafePointer<es_message_t>) {
        switch msg.pointee.event_type {
        case ES_EVENT_TYPE_NOTIFY_EXEC:
            // Re-exec may change identity: drop the cached verdict for this pid.
            let p = pid(msg.pointee.event.exec.target)
            lock.lock(); agentCache[p] = nil; lock.unlock()
        case ES_EVENT_TYPE_NOTIFY_FORK:
            // A fork inherits the parent's verdict until it execs.
            let parent = pid(msg.pointee.process)
            let child = pid(msg.pointee.event.fork.child)
            lock.lock()
            if let v = agentCache[parent] { agentCache[child] = v }
            lock.unlock()
        case ES_EVENT_TYPE_NOTIFY_EXIT:
            let p = pid(msg.pointee.process)
            lock.lock(); agentCache[p] = nil; lock.unlock()
        case ES_EVENT_TYPE_NOTIFY_OPEN:
            _ = authorize(msg, paths: [path(msg.pointee.event.open.file)], op: "open", enforce: false)
        case ES_EVENT_TYPE_AUTH_OPEN:
            let allow = authorize(msg, paths: [path(msg.pointee.event.open.file)], op: "open", enforce: true)
            if let c = client { es_respond_flags_result(c, msg, allow ? .max : 0, false) }
        default:
            let allow = authorizeFileEvent(msg)
            if let c = client { es_respond_auth_result(c, msg, allow ? ES_AUTH_RESULT_ALLOW : ES_AUTH_RESULT_DENY, false) }
        }
    }

    /// Extract the path(s) for the modifying file events and authorize them.
    /// Any event type we didn't expect returns allow (never hang the kernel).
    private func authorizeFileEvent(_ msg: UnsafePointer<es_message_t>) -> Bool {
        let e = msg.pointee.event
        switch msg.pointee.event_type {
        case ES_EVENT_TYPE_AUTH_CREATE:
            let c = e.create
            let p = c.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE
                ? path(c.destination.existing_file)
                : joined(c.destination.new_path.dir, c.destination.new_path.filename)
            return authorize(msg, paths: [p], op: "create", enforce: true)
        case ES_EVENT_TYPE_AUTH_RENAME:
            let r = e.rename
            var paths = [path(r.source)]
            paths.append(r.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE
                ? path(r.destination.existing_file)
                : joined(r.destination.new_path.dir, r.destination.new_path.filename))
            return authorize(msg, paths: paths, op: "rename", enforce: true)
        case ES_EVENT_TYPE_AUTH_UNLINK:
            return authorize(msg, paths: [path(e.unlink.target)], op: "unlink", enforce: true)
        case ES_EVENT_TYPE_AUTH_TRUNCATE:
            return authorize(msg, paths: [path(e.truncate.target)], op: "truncate", enforce: true)
        case ES_EVENT_TYPE_AUTH_LINK:
            return authorize(msg, paths: [path(e.link.source), joined(e.link.target_dir, e.link.target_filename)],
                             op: "link", enforce: true)
        case ES_EVENT_TYPE_AUTH_CLONE:
            return authorize(msg, paths: [path(e.clone.source), joined(e.clone.target_dir, e.clone.target_name)],
                             op: "clone", enforce: true)
        case ES_EVENT_TYPE_AUTH_EXCHANGEDATA:
            return authorize(msg, paths: [path(e.exchangedata.file1), path(e.exchangedata.file2)],
                             op: "exchangedata", enforce: true)
        default:
            return true
        }
    }

    /// true = allow. Denies only when: an attributable agent (not Kai itself)
    /// touches a protected path, and the policy is `block`. Otherwise logs
    /// (would-block) and allows. Fail-open: any path it can't resolve is allowed.
    private func authorize(_ msg: UnsafePointer<es_message_t>, paths: [String], op: String, enforce: Bool) -> Bool {
        let proc = msg.pointee.process
        if isKaiOwnProcess(proc) { return true }
        guard let agent = agentName(proc) else { return true }
        lock.lock(); let pol = policy; lock.unlock()

        var why = [CChar](repeating: 0, count: 256)
        for p in paths where !p.isEmpty {
            if kai_path_protected(pol, p, nil, &why, why.count) == 1 {
                let reason = String(cString: why)
                if enforce && mode == KAI_STORAGE_BLOCK {
                    dlog("BLOCK \(op) \(agent) pid \(pid(proc)) \(p) (\(reason))")
                    audit(decision: "block", agent: agent, op: op, path: p, why: reason)
                    return false
                }
                dlog("would-block \(op) \(agent) pid \(pid(proc)) \(p) (\(reason)) [mode=\(modeName)]")
                audit(decision: "would-block", agent: agent, op: op, path: p, why: reason)
                return true
            }
        }
        return true
    }

    // MARK: adopt console user (read their policy, write their audit log)

    private func adoptConsoleUser() {
        var uid: uid_t = 0, gid: gid_t = 0
        let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid)
        guard name != nil, uid >= 501 else { return }
        userUID = uid; userGID = gid
        if let pw = getpwuid(uid), let home = pw.pointee.pw_dir { setenv("HOME", home, 1) }
    }

    private func audit(decision: String, agent: String, op: String, path: String, why: String) {
        kai_audit("storage", agent, decision, why, "agent \(op) of a protected file")
        if userUID >= 501 {
            let log = String(cString: kai_audit_path())
            chown(log, userUID, userGID)
            chown((log as NSString).deletingLastPathComponent, userUID, userGID)
        }
    }

    deinit {
        if let c = client { es_unsubscribe_all(c); es_delete_client(c) }
        if let p = policy { kai_policy_free(p) }
    }
}
