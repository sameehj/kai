// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai's Endpoint Security client: the OS half of the storage wall.
//
// It authorizes the file operations an agent could use to read a secret or
// tamper with Kai, and hands the path(s) to the tested C engine
// (kai_path_protected). It holds no policy logic of its own.
//
// Overhead-reduction prototypes, selected by the KAI_STORAGE_FILTER env var
// (dev/benchmark only — NOT a user-facing mode):
//   none    (default) authorize every agent-attributable op; no muting.
//   process suppress filesystem auth events for processes POSITIVELY
//           classified as non-agent (es_mute_process_events), keeping their
//           lifecycle events so identity changes are still seen. Unknown and
//           unattributed processes are NEVER muted.
//   path    inverted target-path muting: only deliver events whose target is
//           under a concrete protected directory prefix. (Cannot express
//           glob protects like .env / *.pem anywhere — measured, not shipped.)
//
// Safety invariants held in every mode: lifecycle (EXEC/FORK/EXIT) is always
// delivered; every auth event is always answered; an unresolved path is
// allowed (a bug can't wedge I/O); only Kai's own code-signed processes are
// exempt; when storage protection is off we unsubscribe entirely.
import EndpointSecurity
import Foundation
import KaiCore
import SystemConfiguration

final class StorageClient {
    enum Filter { case none, process, path }

    private var client: OpaquePointer?
    private var policy: OpaquePointer?            // kai_policy*
    private var mode = KAI_STORAGE_LOG
    private let lock = NSLock()
    // pid -> agent name, or "" meaning "checked, not an agent" (negative cache).
    private var agentCache: [pid_t: String] = [:]
    private var policyLoadedAt = Date.distantPast
    private var userUID: uid_t = 0
    private var userGID: gid_t = 0
    private var filter: Filter = .none
    private var fsSubscribed = false              // are the file auth events live?
    private var profiling = false                 // ES-handler timing profiler on?

    // Mirror of enum kai_prof_stage (kai.h), as Int32 so we don't depend on how
    // the C enum imports. Stage timings feed the lock-free C aggregator.
    private enum ProfStage: Int32 { case total = 0, classify, path, policy, respond, deadline }
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()
    @inline(__always) private func nowTicks() -> UInt64 { mach_absolute_time() }
    @inline(__always) private func ticksToNs(_ d: UInt64) -> UInt64 {
        d &* UInt64(StorageClient.timebase.numer) / UInt64(StorageClient.timebase.denom)
    }
    @inline(__always) private func prof(_ s: ProfStage, _ t0: UInt64, _ t1: UInt64) {
        kai_prof_record(s.rawValue, ticksToNs(t1 &- t0))
    }

    // Filesystem auth events the wall authorizes. ES_EVENT_TYPE_AUTH_READDIR
    // exists (verified in the SDK), so directory enumeration is authorized in
    // its own right, not only via AUTH_OPEN of the directory.
    private let fileEvents: [es_event_type_t] = [
        ES_EVENT_TYPE_AUTH_OPEN, ES_EVENT_TYPE_AUTH_CREATE, ES_EVENT_TYPE_AUTH_RENAME,
        ES_EVENT_TYPE_AUTH_UNLINK, ES_EVENT_TYPE_AUTH_TRUNCATE, ES_EVENT_TYPE_AUTH_LINK,
        ES_EVENT_TYPE_AUTH_CLONE, ES_EVENT_TYPE_AUTH_EXCHANGEDATA,
        ES_EVENT_TYPE_AUTH_COPYFILE,   // copying a secret out
        ES_EVENT_TYPE_AUTH_READDIR,    // enumerating a protected directory
    ]
    private let lifecycleEvents: [es_event_type_t] = [
        ES_EVENT_TYPE_NOTIFY_EXEC, ES_EVENT_TYPE_NOTIFY_FORK, ES_EVENT_TYPE_NOTIFY_EXIT,
    ]

    var modeName: String { mode == KAI_STORAGE_BLOCK ? "block" : "log" }

    // MARK: diagnostics (dev build only; root has no readable logs here)
    private func dlog(_ s: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + s + "\n"
        writeFileNoFollow("/tmp/kai-storage.log", Array(line.utf8), append: true)
    }

    /// Write bytes to a fixed path owned by this root process in a world-
    /// writable directory, refusing to follow a symlink an attacker may have
    /// planted there (O_NOFOLLOW on the final component) and setting the mode
    /// through the descriptor, never a path that could be redirected between
    /// calls. Used for both the diagnostic log and the timing snapshot.
    private func writeFileNoFollow(_ path: String, _ bytes: [UInt8], append: Bool) {
        var flags = O_WRONLY | O_CREAT | O_NOFOLLOW
        flags |= append ? O_APPEND : O_TRUNC
        let fd = open(path, flags, 0o644)
        if fd < 0 { return }                       // ELOOP if a symlink is there
        fchmod(fd, 0o644)
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 { _ = write(fd, base, raw.count) }
        }
        close(fd)
    }

    // MARK: lifecycle

    func start() {
        adoptConsoleUser()
        reloadPolicy(force: true)
        // A launchd system extension inherits no shell env, so the dev/benchmark
        // selector is read from a file the user controls: ~/.kai/storage_filter
        // containing one word (none | process | path). Default: none.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let sel = (try? String(contentsOfFile: home + "/.kai/storage_filter", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch sel {
        case "process": filter = .process
        case "path": filter = .path
        default: filter = .none
        }
        // Dev/benchmark ES-handler profiler: on only when ~/.kai/storage_timing
        // exists (a file, since a launchd sysext inherits no env). Default OFF,
        // separate from the filter selector above, never auto-enabled.
        profiling = FileManager.default.fileExists(atPath: home + "/.kai/storage_timing")
        kai_prof_reset(); kai_prof_set_enabled(profiling ? 1 : 0)
        dlog("start: euid=\(geteuid()) adoptedUID=\(userUID) mode=\(modeName) filter=\(filter) profiling=\(profiling)")
        connect()
        scheduleTimingExport()
    }

    /// Snapshot the aggregate timing to a world-readable JSON file every few
    /// seconds, OFF the ES hot path (utility queue) — the authorization
    /// callback itself never does disk I/O for profiling. The file holds only
    /// timing numbers (no paths, no process names), so exporting it touches no
    /// protected user data.
    private func scheduleTimingExport() {
        guard profiling else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.exportTiming()
            self.scheduleTimingExport()
        }
    }

    private func exportTiming() {
        var buf = [CChar](repeating: 0, count: 4096)
        let need = kai_prof_export_json(&buf, buf.count)
        let len = min(need, buf.count - 1)
        let bytes = buf.prefix(len).map { UInt8(bitPattern: $0) }
        writeFileNoFollow("/tmp/kai-storage-timing.json", Array(bytes), append: false)
    }

    private func connect() {
        var c: OpaquePointer?
        let res = es_new_client(&c) { [weak self] _, msg in self?.handle(msg) }
        dlog("es_new_client result=\(res.rawValue)")
        guard res == ES_NEW_CLIENT_RESULT_SUCCESS, let c else {
            if res == ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED {
                dlog("NOT_PERMITTED — grant Kai Full Disk Access. Retrying in 5s.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connect() }
            }
            return
        }
        client = c
        // Lifecycle is always on, in every mode, so classification and identity
        // transitions are never missed.
        _ = es_subscribe(c, lifecycleEvents, UInt32(lifecycleEvents.count))
        if filter == .path { setupPathMuting(c) }
        syncSubscription()
    }

    /// Subscribe the file auth events when protection is on; unsubscribe them
    /// when it's off, so "off" truly costs nothing. Called on policy reloads.
    private func syncSubscription() {
        guard let c = client else { return }
        let wantOn = (mode != KAI_STORAGE_OFF)
        #if !KAI_STORAGE_ENFORCE
        // A non-enforcing build only observes opens; never subscribe auth events.
        if wantOn && !fsSubscribed { _ = es_subscribe(c, [ES_EVENT_TYPE_NOTIFY_OPEN], 1); fsSubscribed = true }
        return
        #else
        if wantOn && !fsSubscribed {
            _ = es_subscribe(c, fileEvents, UInt32(fileEvents.count))
            fsSubscribed = true
            dlog("subscribed \(fileEvents.count) file auth events (mode=\(modeName) filter=\(filter))")
        } else if !wantOn && fsSubscribed {
            for e in fileEvents { _ = es_unsubscribe(c, [e], 1) }
            fsSubscribed = false
            dlog("storage off: unsubscribed file auth events (zero overhead)")
        }
        #endif
    }

    /// Inverted target-path muting: deliver events only for targets under a
    /// concrete protected directory. Glob protects (.env / *.pem anywhere)
    /// have no fixed prefix and are therefore NOT covered in this mode.
    private func setupPathMuting(_ c: OpaquePointer) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let prefixes = ["/.ssh", "/.aws", "/.kai", "/.config/gcloud", "/.claude", "/.cursor", "/.codex"]
            .map { home + $0 }
        es_invert_muting(c, ES_MUTE_INVERSION_TYPE_TARGET_PATH)
        for p in prefixes { _ = es_mute_path(c, p, ES_MUTE_PATH_TYPE_TARGET_PREFIX) }
        dlog("path filter: inverted target-path muting to \(prefixes.count) prefixes")
    }

    private func reloadPolicy(force: Bool) {
        lock.lock()
        if !force && Date().timeIntervalSince(policyLoadedAt) < 2 { lock.unlock(); return }
        if let p = policy { kai_policy_free(p) }
        policy = kai_policy_load(nil, nil, 0)
        let newMode = kai_policy_storage_mode(policy)
        let changed = newMode != mode
        mode = newMode
        policyLoadedAt = Date()
        lock.unlock()
        if changed { syncSubscription() }
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

    private func isKaiOwnProcess(_ proc: UnsafeMutablePointer<es_process_t>) -> Bool {
        let flags = proc.pointee.codesigning_flags
        let csValid: UInt32 = 0x1, csAdhoc: UInt32 = 0x2
        guard (flags & csValid) != 0, (flags & csAdhoc) == 0 else { return false }
        return esString(proc.pointee.team_id) == "KD446VDTM2"
    }

    /// Returns the agent name, "" for a positively-classified non-agent, or nil
    /// if we cannot read the process at all (treated as unknown — never muted).
    private func classify(_ proc: UnsafeMutablePointer<es_process_t>) -> String? {
        let p = pid(proc)
        lock.lock()
        if let cached = agentCache[p] { lock.unlock(); return cached }
        let pol = policy
        lock.unlock()
        var name = [CChar](repeating: 0, count: 64)
        var result: String? = ""
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
        return result
    }

    private func muteFS(_ proc: UnsafeMutablePointer<es_process_t>, _ on: Bool) {
        guard filter == .process, let c = client else { return }
        var token = proc.pointee.audit_token
        withUnsafePointer(to: &token) { tp in
            if on { _ = es_mute_process_events(c, tp, fileEvents, fileEvents.count) }
            else { _ = es_unmute_process_events(c, tp, fileEvents, fileEvents.count) }
        }
    }

    // MARK: event handling

    private func handle(_ msg: UnsafePointer<es_message_t>) {
        switch msg.pointee.event_type {
        case ES_EVENT_TYPE_NOTIFY_EXEC:
            let target = msg.pointee.event.exec.target
            let p = pid(target)
            lock.lock(); agentCache[p] = nil; lock.unlock()   // re-exec: drop stale verdict
            // process filter: suppress file events only for POSITIVELY-classified
            // non-agents; keep watching agents and never mute unknowns (nil).
            if filter == .process, !isKaiOwnProcess(target) {
                if let v = classify(target) { muteFS(target, v.isEmpty) }
            }
        case ES_EVENT_TYPE_NOTIFY_FORK:
            let parent = pid(msg.pointee.process)
            let child = pid(msg.pointee.event.fork.child)
            lock.lock(); if let v = agentCache[parent] { agentCache[child] = v }; lock.unlock()
            // Do NOT mute the child here: a fresh pid is unknown until it execs.
        case ES_EVENT_TYPE_NOTIFY_EXIT:
            let p = pid(msg.pointee.process)
            lock.lock(); agentCache[p] = nil; lock.unlock()
        case ES_EVENT_TYPE_NOTIFY_OPEN:
            _ = authorize(msg, paths: [path(msg.pointee.event.open.file)], op: "open", enforce: false)
        case ES_EVENT_TYPE_AUTH_OPEN:
            let t0 = profiling ? nowTicks() : 0
            let p = path(msg.pointee.event.open.file)
            let tPaths = profiling ? nowTicks() : 0
            let allow = authorize(msg, paths: [p], op: "open", enforce: true, timed: profiling, t0: t0, tPaths: tPaths)
            let tResp = profiling ? nowTicks() : 0
            if let c = client { es_respond_flags_result(c, msg, allow ? .max : 0, false) }
            finishTiming(msg, t0: t0, tResp: tResp)
        default:
            let t0 = profiling ? nowTicks() : 0
            let (paths, op) = extractPaths(msg)
            let tPaths = profiling ? nowTicks() : 0
            let allow = authorize(msg, paths: paths, op: op, enforce: true, timed: profiling, t0: t0, tPaths: tPaths)
            let tResp = profiling ? nowTicks() : 0
            if let c = client { es_respond_auth_result(c, msg, allow ? ES_AUTH_RESULT_ALLOW : ES_AUTH_RESULT_DENY, false) }
            finishTiming(msg, t0: t0, tResp: tResp)
        }
    }

    /// Record RESPOND / TOTAL and the ES deadline margin once the auth result
    /// is sent. Runs only when profiling; adds nothing otherwise.
    private func finishTiming(_ msg: UnsafePointer<es_message_t>, t0: UInt64, tResp: UInt64) {
        guard profiling else { return }
        let end = nowTicks()
        prof(.respond, tResp, end)
        prof(.total, t0, end)
        let deadline = msg.pointee.deadline            // mach-time absolute
        if deadline > end { kai_prof_record(ProfStage.deadline.rawValue, ticksToNs(deadline &- end)) }
    }

    /// Pull the target path(s) and a label out of a file auth event. Returns an
    /// empty list for event types the wall doesn't gate (authorize then allows).
    private func extractPaths(_ msg: UnsafePointer<es_message_t>) -> ([String], String) {
        let e = msg.pointee.event
        switch msg.pointee.event_type {
        case ES_EVENT_TYPE_AUTH_CREATE:
            let c = e.create
            let p = c.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE
                ? path(c.destination.existing_file) : joined(c.destination.new_path.dir, c.destination.new_path.filename)
            return ([p], "create")
        case ES_EVENT_TYPE_AUTH_RENAME:
            let r = e.rename
            var paths = [path(r.source)]
            paths.append(r.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE
                ? path(r.destination.existing_file) : joined(r.destination.new_path.dir, r.destination.new_path.filename))
            return (paths, "rename")
        case ES_EVENT_TYPE_AUTH_UNLINK:
            return ([path(e.unlink.target)], "unlink")
        case ES_EVENT_TYPE_AUTH_TRUNCATE:
            return ([path(e.truncate.target)], "truncate")
        case ES_EVENT_TYPE_AUTH_LINK:
            return ([path(e.link.source), joined(e.link.target_dir, e.link.target_filename)], "link")
        case ES_EVENT_TYPE_AUTH_CLONE:
            return ([path(e.clone.source), joined(e.clone.target_dir, e.clone.target_name)], "clone")
        case ES_EVENT_TYPE_AUTH_EXCHANGEDATA:
            return ([path(e.exchangedata.file1), path(e.exchangedata.file2)], "exchangedata")
        case ES_EVENT_TYPE_AUTH_READDIR:
            return ([path(e.readdir.target)], "readdir")
        case ES_EVENT_TYPE_AUTH_COPYFILE:
            var paths = [path(e.copyfile.source)]
            if let tf = e.copyfile.target_file { paths.append(path(tf)) }
            else { paths.append(joined(e.copyfile.target_dir, e.copyfile.target_name)) }
            return (paths, "copyfile")
        default:
            return ([], "other")
        }
    }

    private func authorize(_ msg: UnsafePointer<es_message_t>, paths: [String], op: String,
                           enforce: Bool, timed: Bool = false, t0: UInt64 = 0, tPaths: UInt64 = 0) -> Bool {
        if timed { prof(.path, t0, tPaths) }
        let proc = msg.pointee.process
        let tClassify = timed ? nowTicks() : 0
        if isKaiOwnProcess(proc) {
            if timed { prof(.classify, tClassify, nowTicks()) }
            return true
        }
        let agentName = classify(proc)
        if timed { prof(.classify, tClassify, nowTicks()) }
        guard let agent = agentName, !agent.isEmpty else { return true }
        lock.lock(); let pol = policy; lock.unlock()
        var why = [CChar](repeating: 0, count: 256)
        let tPolicy = timed ? nowTicks() : 0
        for p in paths where !p.isEmpty {
            if kai_path_protected(pol, p, nil, &why, why.count) == 1 {
                if timed { prof(.policy, tPolicy, nowTicks()) }
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
        if timed { prof(.policy, tPolicy, nowTicks()) }
        return true
    }

    // MARK: console user + audit

    private func adoptConsoleUser() {
        var uid: uid_t = 0, gid: gid_t = 0
        let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid)
        guard name != nil, uid >= 501 else { return }
        userUID = uid; userGID = gid
        if let pwent = getpwuid(uid), let home = pwent.pointee.pw_dir { setenv("HOME", home, 1) }
    }

    private func audit(decision: String, agent: String, op: String, path: String, why: String) {
        // Record the actual target path (not just the matched rule) via the
        // richer audit entry, so the activity view and `kai log` show WHICH file
        // was touched. A path is an identifier, not file contents; the audit
        // layer still caps target length (KAI_AUDIT_TARGET_MAX).
        let detail = "agent \(op) of a protected file"
        "storage".withCString { src in agent.withCString { ev in
        decision.withCString { dec in why.withCString { rl in
        detail.withCString { det in op.withCString { tl in
        path.withCString { tg in
            var e = kai_audit_entry(source: src, event: ev, decision: dec, rule: rl,
                                    detail: det, tool: tl, target: tg,
                                    match: nil, session: nil, cwd: nil)
            kai_audit_write(&e)
        }}}}}}}
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
