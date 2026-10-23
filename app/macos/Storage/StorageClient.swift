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

    /// Does this open() carry write intent? Read-only opens of an agent's own
    /// hook config are allowed; writes to it are blocked (anti-tamper).
    @inline(__always) private func openIsWrite(_ fflag: Int32) -> Bool {
        (fflag & O_ACCMODE) != O_RDONLY || (fflag & (O_CREAT | O_TRUNC | O_APPEND)) != 0
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
        #if KAI_STORAGE_ENFORCE
        openGrantStore()
        #endif
        scheduleHealth()
    }

    /// Write a measured-health snapshot every 5s, OFF the hot path, so `kai
    /// status` can show OBSERVED state (is the extension actually running, in
    /// which mode, enforcing, which grant generation) distinct from configured
    /// state. World-readable timing-only JSON; no paths or secrets.
    private func scheduleHealth() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.writeHealth()
            self.scheduleHealth()
        }
    }

    private var pausedStorage = false   // refreshed off the hot path (health timer)

    private func writeHealth() {
        pausedStorage = kai_wall_paused("storage", Int64(Date().timeIntervalSince1970)) != 0
        var enforcing = false
        var gen: UInt = 0
        #if KAI_STORAGE_ENFORCE
        enforcing = (mode == KAI_STORAGE_BLOCK)
        if let gs = grantStore { gen = kai_approval_store_generation(gs) }
        #endif
        let json = "{\"wall\":\"storage\",\"mode\":\"\(modeName)\",\"enforcing\":\(enforcing)," +
                   "\"filter\":\"\(filter)\",\"grant_generation\":\(gen)," +
                   "\"ts\":\(Int(Date().timeIntervalSince1970))}"
        writeFileNoFollow("/tmp/kai-storage-health.json", Array(json.utf8), append: false)
    }

    #if KAI_STORAGE_ENFORCE
    // MARK: Scoped Approvals (M4) — grants can allow a SOFT-protected op when a
    // valid, human-approved grant matches. Active only when an approval key
    // exists (otherwise nil => no behaviour change: protected still denies).
    private var grantStore: OpaquePointer?            // kai_approval_store*
    private var pendingSeen = Set<String>()           // dedup approval requests

    private func openGrantStore() {
        // Open the authorization snapshot ALWAYS (even with no key): it is the
        // single coherent (policy + grants) snapshot, reloaded atomically, that
        // both the protect gate and the grant decision read -- so there is no
        // self.policy/grant-policy divergence, and a protect rule added after
        // start IS enforced. Without a key, grants simply can't be honored
        // (HMAC can't verify), so the store is policy-only.
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let gdir = home + "/.kai/grants"
        let key = FileManager.default.contents(atPath: home + "/.kai/approval.key") ?? Data()
        if key.isEmpty {
            grantStore = kai_approval_store_open(nil, gdir, nil, 0, 2)
            dlog("grants: store opened policy-only (no approval key; grants not honored)")
        } else {
            key.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                    grantStore = kai_approval_store_open(nil, gdir, base, key.count, 2)
                }
            }
            dlog("grants: store opened with approval key")
        }
        if grantStore != nil { scheduleGrantReload() }
    }

    /// Re-read policy+grants on a timer (the store debounces the re-stat), so a
    /// new/revoked grant reaches the running wall without a restart. Off the ES
    /// hot path; the store itself is thread-safe.
    private func scheduleGrantReload() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let gs = self.grantStore else { return }
            _ = kai_approval_store_reload(gs, 0)
            self.scheduleGrantReload()
        }
    }

    private func opCode(_ op: String) -> Int32 {
        switch op { case "open", "readdir": return 0 /* read */ default: return 1 /* write */ }
    }

    /// Does a valid, human-approved grant allow this exact op? The store refuses
    /// to honor a grant for an un-exemptable control path, verifies the HMAC,
    /// checks expiry, binds identity to pid+pidversion, and consumes one-shots.
    private func grantAllows(_ proc: UnsafeMutablePointer<es_process_t>,
                             path p: String, agent: String, opStr: String) -> Bool {
        guard let gs = grantStore else { return false }
        let flags = proc.pointee.codesigning_flags
        let strong = (flags & 0x1) != 0 && (flags & 0x2) == 0  // valid, non-adhoc
        let subjStrength: Int32 = strong ? 2 : 1               // strong : medium
        let token = proc.pointee.audit_token
        let sess = sessionFor(pid(proc))
        var ok = false
        var why = [CChar](repeating: 0, count: 256)
        agent.withCString { ap in sess.sid.withCString { sp in sess.project.withCString { pp in
            var subj = kai_grant_subject(pid: pid(proc), pidversion: UInt64(token.val.7),
                                         agent: ap, strength: subjStrength,
                                         session_id: sp, project: pp)
            let now = Int64(Date().timeIntervalSince1970)
            ok = kai_approval_store_decide(gs, p, nil, opCode(opStr), &subj, now, &why, why.count) == 1
        }}}
        return ok
    }

    /// Stage an approval request for the app to surface (async; the ES callback
    /// is never held). Deduped per (pid, op, path). Only KAI-verified fields are
    /// recorded — the agent name is Kai's classification, not agent-supplied.
    private func requestApproval(_ proc: UnsafeMutablePointer<es_process_t>,
                                 path p: String, agent: String, opStr: String) {
        let dkey = "\(pid(proc)):\(opStr):\(p)"
        lock.lock()
        let seen = pendingSeen.contains(dkey)
        if !seen { if pendingSeen.count > 4096 { pendingSeen.removeAll() }; pendingSeen.insert(dkey) }
        lock.unlock()
        if seen { return }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = home + "/.kai/pending"
        mkdir(dir, 0o700)
        let token = proc.pointee.audit_token
        let id = "\(pid(proc))-\(UInt64(token.val.7))-\(Int(Date().timeIntervalSince1970))"
        let flags = proc.pointee.codesigning_flags
        let strength = ((flags & 0x1) != 0 && (flags & 0x2) == 0) ? 2 : 1   // strong : medium
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let json = "{\"id\":\"\(id)\",\"agent\":\"\(esc(agent))\",\"pid\":\(pid(proc))," +
                   "\"pidversion\":\(UInt64(token.val.7)),\"strength\":\(strength)," +
                   "\"resource\":\"\(esc(p))\",\"op\":\"\(esc(opStr))\"," +
                   "\"ts\":\(Int(Date().timeIntervalSince1970))}"
        let fp = dir + "/" + id + ".json"
        writeFileNoFollow(fp, Array(json.utf8), append: false)
        if userUID >= 501 { chown(fp, userUID, userGID); chown(dir, userUID, userGID) }
        kai_grant_audit("requested", id, agent, p, opCode(opStr), "request", "awaiting approval")
    }

    // MARK: M1.2 session identity
    // A session id is minted at a recognized agent's ROOT exec (keyed on its
    // audit token), inherited by children, and written to a shared file the
    // network extension can read -- so "Allow for this session" covers the
    // child processes (ssh, node) that actually open files/connections.
    private var sessions: [pid_t: (sid: String, project: String)] = [:]

    private func cwdOf(_ p: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(p, PROC_PIDVNODEPATHINFO, 0, &info, sz) > 0 else { return "" }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
    }

    private func sessionPath(_ p: pid_t) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + "/.kai/sessions/\(p).json"
    }

    private func writeSessionFile(pid p: pid_t, pidv: UInt32, sid: String, project: String) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = home + "/.kai/sessions"
        mkdir(dir, 0o700)
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let json = "{\"pid\":\(p),\"pidversion\":\(pidv),\"session\":\"\(esc(sid))\"," +
                   "\"project\":\"\(esc(project))\"}"
        writeFileNoFollow(sessionPath(p), Array(json.utf8), append: false)
        if userUID >= 501 { chown(sessionPath(p), userUID, userGID); chown(dir, userUID, userGID) }
    }

    /// Mint (root) or inherit (child) a session for an agent process `proc`.
    private func mintSession(_ proc: UnsafeMutablePointer<es_process_t>) {
        let p = pid(proc)
        let ppid = proc.pointee.ppid
        let pidv = UInt32(proc.pointee.audit_token.val.7)
        lock.lock()
        let entry: (sid: String, project: String) = sessions[ppid] ?? (UUID().uuidString, cwdOf(p))
        if sessions.count > 8192 { sessions.removeAll() }
        sessions[p] = entry
        lock.unlock()
        writeSessionFile(pid: p, pidv: pidv, sid: entry.sid, project: entry.project)
    }

    private func sessionFor(_ p: pid_t) -> (sid: String, project: String) {
        lock.lock(); defer { lock.unlock() }
        return sessions[p] ?? ("", "")
    }

    private func dropSession(_ p: pid_t) {
        lock.lock(); sessions[p] = nil; lock.unlock()
        try? FileManager.default.removeItem(atPath: sessionPath(p))
    }
    #endif

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
            if !isKaiOwnProcess(target) {
                let v = classify(target)                      // agent name, "" non-agent, nil unknown
                if filter == .process, let v { muteFS(target, v.isEmpty) }
                #if KAI_STORAGE_ENFORCE
                if let v, !v.isEmpty { mintSession(target) }  // agents get/inherit a session
                #endif
            }
        case ES_EVENT_TYPE_NOTIFY_FORK:
            let parent = pid(msg.pointee.process)
            let child = pid(msg.pointee.event.fork.child)
            lock.lock()
            if let v = agentCache[parent] { agentCache[child] = v }
            #if KAI_STORAGE_ENFORCE
            let parentSession = sessions[parent]
            if let s = parentSession { sessions[child] = s }
            #endif
            lock.unlock()
            #if KAI_STORAGE_ENFORCE
            if let s = parentSession {                        // child shares the session before it execs
                writeSessionFile(pid: child, pidv: UInt32(msg.pointee.event.fork.child.pointee.audit_token.val.7),
                                 sid: s.sid, project: s.project)
            }
            #endif
            // Do NOT mute the child here: a fresh pid is unknown until it execs.
        case ES_EVENT_TYPE_NOTIFY_EXIT:
            let p = pid(msg.pointee.process)
            lock.lock(); agentCache[p] = nil; lock.unlock()
            #if KAI_STORAGE_ENFORCE
            dropSession(p)
            #endif
        case ES_EVENT_TYPE_NOTIFY_OPEN:
            _ = authorize(msg, paths: [path(msg.pointee.event.open.file)], op: "open", enforce: false, write: false)
        case ES_EVENT_TYPE_AUTH_OPEN:
            let t0 = profiling ? nowTicks() : 0
            let p = path(msg.pointee.event.open.file)
            let tPaths = profiling ? nowTicks() : 0
            let w = openIsWrite(msg.pointee.event.open.fflag)
            let allow = authorize(msg, paths: [p], op: "open", enforce: true, write: w, timed: profiling, t0: t0, tPaths: tPaths)
            let tResp = profiling ? nowTicks() : 0
            if let c = client { es_respond_flags_result(c, msg, allow ? .max : 0, false) }
            finishTiming(msg, t0: t0, tResp: tResp)
        default:
            let t0 = profiling ? nowTicks() : 0
            let (paths, op) = extractPaths(msg)
            let tPaths = profiling ? nowTicks() : 0
            // readdir is a read; every other gated event mutates the target.
            let allow = authorize(msg, paths: paths, op: op, enforce: true, write: op != "readdir",
                                  timed: profiling, t0: t0, tPaths: tPaths)
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
                           enforce: Bool, write: Bool = true,
                           timed: Bool = false, t0: UInt64 = 0, tPaths: UInt64 = 0) -> Bool {
        if timed { prof(.path, t0, tPaths) }
        if pausedStorage { return true }   // wall paused (time-boxed, auto-resume): allow
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
            // Protect check over the ONE coherent snapshot: the grant store's
            // reloaded policy when it is open (enforce builds), else self.policy.
            var hit = false
            #if KAI_STORAGE_ENFORCE
            if let gs = grantStore { hit = kai_approval_store_protected(gs, p, nil, &why, why.count) == 1 }
            else { hit = kai_path_protected(pol, p, nil, &why, why.count) == 1 }
            #else
            hit = kai_path_protected(pol, p, nil, &why, why.count) == 1
            #endif
            if hit {
                if timed { prof(.policy, tPolicy, nowTicks()) }
                let reason = String(cString: why)
                // An agent READING its own hook config (not Kai's home, not a
                // secret) is allowed: it must to start, and Kai's hooks live
                // there, so blocking the read is self-defeating. WRITES to it are
                // still blocked below (anti-tamper); Kai's home stays read-blocked.
                if !write && kai_control_read_allowed(why) == 1 { return true }
                if enforce && mode == KAI_STORAGE_BLOCK {
                    #if KAI_STORAGE_ENFORCE
                    // A valid, human-approved grant can allow a soft-protected
                    // op. The store refuses control paths, so this never widens
                    // an un-exemptable denial.
                    if grantAllows(proc, path: p, agent: agent, opStr: op) {
                        dlog("ALLOW-GRANT \(op) \(agent) pid \(pid(proc)) \(p)")
                        audit(decision: "allow-grant", agent: agent, op: op, path: p, why: reason)
                        kai_grant_audit("used", "(granted)", agent, p, opCode(op), "allow", "scoped grant")
                        return true
                    }
                    requestApproval(proc, path: p, agent: agent, opStr: op)
                    #endif
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
        // Structured denial record: reason code "protected_resource" in `rule`,
        // the matched protect rule in `match`, and the actual path in `target` --
        // so the Activity view and `kai why` show WHICH file and WHY, and the
        // record never mislabels the path as a rule. A path is an identifier, not
        // file contents; the audit layer caps target length.
        let detail = "agent \(op) of a protected file"
        kai_denial_audit("storage", agent, decision, path, op,
                         KAI_REASON_PROTECTED, why, detail)
        if userUID >= 501 {
            let log = String(cString: kai_audit_path())
            chown(log, userUID, userGID)
            chown((log as NSString).deletingLastPathComponent, userUID, userGID)
        }
    }

    deinit {
        if let c = client { es_unsubscribe_all(c); es_delete_client(c) }
        if let p = policy { kai_policy_free(p) }
        #if KAI_STORAGE_ENFORCE
        if let gs = grantStore { kai_approval_store_close(gs) }
        #endif
    }
}
