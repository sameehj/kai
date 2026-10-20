// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Kai's Endpoint Security client: the OS half of the storage wall. It gathers
// the facts the decision needs and hands them to the tested C engine
// (kai_storage_open_allowed); it holds no policy logic of its own.
//
// Two modes, chosen from the policy's `storage` setting:
//   log   -> subscribe NOTIFY_OPEN. Observe and log "would block". No deadline,
//            cannot stall the machine. This is the default and the safe one.
//   block -> subscribe AUTH_OPEN and actually deny. Compiled ONLY when
//            KAI_STORAGE_ENFORCE is defined, because a wrong/slow AUTH handler
//            stalls every file open on the machine. Validate on a VM first.
//
// Agent processes are tagged once, at exec time (off the open hot path), and
// cached by pid; the open handler is an O(1) lookup plus the path check.
import EndpointSecurity
import Foundation
import KaiCore
import SystemConfiguration

final class StorageClient {
    private var client: OpaquePointer?
    private var policy: OpaquePointer?            // kai_policy*
    private var mode = KAI_STORAGE_LOG
    private let lock = NSLock()
    private var agents: [pid_t: String] = [:]     // pid -> agent name, tagged at exec
    private var policyLoadedAt = Date.distantPast
    private var sawAgentOpen = false              // diagnostics: did any agent open reach us

    var modeName: String { mode == KAI_STORAGE_BLOCK ? "block" : "log" }

    // Development diagnostics: the extension runs as root with no readable
    // logs here, so append a world-readable status line to /tmp. This exists
    // only in the dev storage build and lets `cat /tmp/kai-storage.log` show
    // what the client actually did (es_new_client result, mode, decisions).
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

    func start() {
        adoptConsoleUser()   // read/write the logged-in user's policy and audit log, not root's
        reloadPolicy(force: true)
        dlog("start: euid=\(geteuid()) adoptedUID=\(userUID) home=\(ProcessInfo.processInfo.environment["HOME"] ?? "?") mode=\(modeName) policyLoaded=\(policy != nil)")
        connect()
    }

    /// Create the ES client and subscribe. es_new_client returns
    /// ERR_NOT_PERMITTED (4) until the user grants Kai Full Disk Access, so on
    /// that result we keep retrying — once they grant it, the wall comes up on
    /// its own within a few seconds, no toggle needed.
    private func connect() {
        var c: OpaquePointer?
        let res = es_new_client(&c) { [weak self] _, msg in
            self?.handle(msg)
        }
        dlog("es_new_client result=\(res.rawValue) (success=\(res == ES_NEW_CLIENT_RESULT_SUCCESS))")
        guard res == ES_NEW_CLIENT_RESULT_SUCCESS, let c else {
            if res == ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED {
                dlog("NOT_PERMITTED — grant Kai Full Disk Access in System Settings > Privacy & Security. Retrying in 5s.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connect() }
            }
            return
        }
        client = c

        // Tag agents by watching process lifecycle (notify: no deadline).
        var events: [es_event_type_t] = [ES_EVENT_TYPE_NOTIFY_EXEC, ES_EVENT_TYPE_NOTIFY_EXIT]
        // Blocking is gated at compile time so a released/notify build can
        // never deny. When compiled in, subscribe AUTH_OPEN regardless of the
        // current mode: the handler allows (and logs "would block") unless the
        // policy is `block`, so switching Watch<->Block takes effect live, with
        // no restart. Non-block answers are immediate, so there's no added
        // deadline risk beyond the (fast) agent lookup.
        #if KAI_STORAGE_ENFORCE
        events.append(ES_EVENT_TYPE_AUTH_OPEN)
        #else
        events.append(ES_EVENT_TYPE_NOTIFY_OPEN) // observe only; never deny
        #endif

        let sub = es_subscribe(c, events, UInt32(events.count))
        dlog("es_subscribe result=\(sub.rawValue) events=\(events.count); enforcing in mode=\(modeName)")
    }

    // MARK: policy

    private func reloadPolicy(force: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !force && Date().timeIntervalSince(policyLoadedAt) < 2 { return }
        if let p = policy { kai_policy_free(p) }
        policy = kai_policy_load(nil, nil, 0)
        mode = kai_policy_storage_mode(policy)
        policyLoadedAt = Date()
    }

    // MARK: event handling

    // pid lives in audit_token.val[5]; read it directly rather than link
    // libbsm for audit_token_to_pid (the network extension does the same).
    private func pid(_ proc: UnsafeMutablePointer<es_process_t>) -> pid_t {
        pid_t(bitPattern: proc.pointee.audit_token.val.5)
    }

    private func esString(_ t: es_string_token_t) -> String {
        guard let d = t.data, t.length > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: d, count: t.length), as: UTF8.self)
    }

    /// Kai's own signed binaries (CLI, hooks, the extensions) must never be
    /// blocked from reading ~/.kai — otherwise enabling the wall breaks Kai's
    /// own policy loading. They are descendants of the agent, so agent tagging
    /// would catch them; exempt them by code signature (our team / bundle id),
    /// which an agent-dropped binary can't forge.
    private func isKaiOwnProcess(_ proc: UnsafeMutablePointer<es_process_t>) -> Bool {
        // Trust only a real code signature from Kai's Apple Developer team, and
        // require the platform/code-signing to be valid (no ad-hoc). An agent
        // can set a binary's *name* or ad-hoc *signing id* to "kai", but it
        // cannot sign with this team's certificate. Never trust the name.
        let flags = proc.pointee.codesigning_flags
        let csValid: UInt32 = 0x1          // CS_VALID
        let csAdhoc: UInt32 = 0x2          // CS_ADHOC
        guard (flags & csValid) != 0, (flags & csAdhoc) == 0 else { return false }
        return esString(proc.pointee.team_id) == "KD446VDTM2"
    }

    private func handle(_ msg: UnsafePointer<es_message_t>) {
        switch msg.pointee.event_type {
        case ES_EVENT_TYPE_NOTIFY_EXEC:
            tagExec(msg)
        case ES_EVENT_TYPE_NOTIFY_EXIT:
            let p = pid(msg.pointee.process)
            lock.lock(); agents[p] = nil; lock.unlock()
        case ES_EVENT_TYPE_NOTIFY_OPEN:
            _ = decide(msg, enforce: false)
        case ES_EVENT_TYPE_AUTH_OPEN:
            let allow = decide(msg, enforce: true)
            // Flags the process may keep: all = allow, none = deny.
            let authorized: UInt32 = allow ? .max : 0
            if let c = client { es_respond_flags_result(c, msg, authorized, false) }
        default:
            break
        }
    }

    /// At exec, decide once whether the new process is an agent (or under one)
    /// and cache it, so the open path never walks the process tree.
    private func tagExec(_ msg: UnsafePointer<es_message_t>) {
        let target = msg.pointee.event.exec.target
        let p = pid(target)
        if isKaiOwnProcess(target) { return }   // Kai's own tools are never blockable agents
        reloadPolicy(force: false)
        lock.lock()
        let pol = policy
        // A child of a tagged agent is an agent too, even if its own image
        // doesn't match (e.g. an agent spawning /bin/sh).
        let parent = agents[target.pointee.ppid]
        lock.unlock()
        var name = [CChar](repeating: 0, count: 64)
        let isAgent = parent != nil || kai_process_agent(pol, p, &name, name.count, nil) == 1
        if isAgent {
            let n = parent ?? String(cString: name)
            lock.lock(); if agents.count < 8192 { agents[p] = n }; lock.unlock()
        }
    }

    /// Returns true to allow. Logs would-block in notify mode; in auth mode the
    /// caller turns false into a deny.
    private func decide(_ msg: UnsafePointer<es_message_t>, enforce: Bool) -> Bool {
        if isKaiOwnProcess(msg.pointee.process) { return true }  // never block Kai reading its own files
        let p = pid(msg.pointee.process)
        lock.lock()
        guard let agent = agents[p] else { lock.unlock(); return true } // not an agent: never touched
        let pol = policy
        if !sawAgentOpen { sawAgentOpen = true; lock.unlock(); dlog("first agent open observed from \(agent) (pid \(p))") }
        else { lock.unlock() }

        let path = String(cString: msg.pointee.event.open.file.pointee.path.data)
        let write = (msg.pointee.event.open.fflag & Int32(FWRITE)) != 0
        var why = [CChar](repeating: 0, count: 256)
        // Ask block mode's answer regardless of the live mode, so notify builds
        // still show what enforcement would do.
        let protected = kai_path_protected(pol, path, nil, &why, why.count) == 1
        if !protected { return true }

        let reason = String(cString: why)
        _ = write  // every protected path is denied to non-Kai agents, read or write
        if enforce && mode == KAI_STORAGE_BLOCK {
            dlog("BLOCK \(agent) pid \(p) \(path) (\(reason))")
            audit(decision: "block", agent: agent, path: path, why: reason)
            return false
        }
        dlog("would-block \(agent) pid \(p) \(path) (\(reason)) [mode=\(modeName)]")
        audit(decision: "would-block", agent: agent, path: path, why: reason)
        return true
    }

    // The logged-in user, so we read their policy and write their audit log
    // (we run as root, whose ~/.kai is not the user's).
    private var userUID: uid_t = 0
    private var userGID: gid_t = 0

    private func adoptConsoleUser() {
        var uid: uid_t = 0, gid: gid_t = 0
        let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid)
        guard name != nil, uid >= 501 else { return }   // a real logged-in user, not loginwindow
        userUID = uid
        userGID = gid
        if let pw = getpwuid(uid), let home = pw.pointee.pw_dir {
            setenv("HOME", home, 1)        // kai_policy_load / kai_home() now resolve to the user's ~/.kai
        }
    }

    private func audit(decision: String, agent: String, path: String, why: String) {
        kai_audit("storage", agent, decision, why, "agent open of a protected file")
        // We run as root; keep the user's audit log owned by the user so their
        // CLI/app can read and extend it (the network extension does the same).
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
