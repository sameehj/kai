// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// 0.5.1 "Blocked sites": one block list. A plain host is the same rule as
// `kai block <host>` (agent-rules.json, every agent): the hooks keep stopping
// shell commands and web fetches that name it, always. An address, range or
// host:port goes in the policy's `egress_block` lines. In "Watch + block my
// list" the network extension also refuses agents' new connections to
// everything here (src/net.c kai_egress_blocklist_drop).
//
// The app writes in-process, like every other Kai setting. Nothing here
// changes how the Files (Storage) wall enforces anything.
import Foundation
import KaiCore

@MainActor
final class BlockList: ObservableObject {
    static let shared = BlockList()

    struct Entry: Identifiable, Equatable {
        var value: String
        var agent: String          // "*" = every agent
        var fromPolicy: Bool       // an egress_block line
        var id: String { (fromPolicy ? "p:" : "r:") + agent + ":" + value }
        var agentWords: String { agent == "*" ? "Every agent" : ActivityFeed.agentTitle(agent) }
    }

    @Published private(set) var entries: [Entry] = []
    /// "Turn on blocking for your list?" waits for an answer (asked once).
    @Published var offerTurnOn = false
    @Published var lastError: String?

    private static let askedKey = "blocklistAskedTurnOn"
    private static let starterKey = "blocklistStarterOffered"

    var starterOffered: Bool {
        get { UserDefaults.standard.bool(forKey: Self.starterKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.starterKey); objectWillChange.send() }
    }

    var hosts: [String] { entries.map(\.value) }

    func refresh(policy: PolicyInfo?) {
        #if DEBUG
        if ScreenshotFixture.active { return }
        #endif
        var out: [Entry] = []
        var i: Int32 = 0
        var a: UnsafePointer<CChar>? = nil, h: UnsafePointer<CChar>? = nil
        while kai_agent_block_at(i, &a, &h) == 1, let a, let h {
            out.append(Entry(value: String(cString: h), agent: String(cString: a), fromPolicy: false))
            i += 1
        }
        for v in policy?.egressBlock ?? [] { out.append(Entry(value: v, agent: "*", fromPolicy: true)) }
        if out != entries { entries = out }
    }

    func contains(_ host: String) -> Bool { BlockStarter.covers(hosts.filter(BlockStarter.isPlainHost), host) }

    /// Add a site. `model` writes policy lines (addresses, ranges, ports).
    /// Returns false when the value isn't a site Kai can block.
    @discardableResult
    func add(_ raw: String, model: AppModel) -> Bool {
        lastError = nil
        guard let v = BlockStarter.normalize(raw) else {
            lastError = "“\(raw)” isn't a site name, address or range."
            return false
        }
        if BlockStarter.isPlainHost(v) {
            if entries.contains(where: { !$0.fromPolicy && $0.agent == "*" && $0.value == v }) { return true }
            guard kai_agent_rule_add(Int32(KAI_AGENT_RULE_BLOCK), "*", v, 0) == 0 else {
                lastError = "Kai couldn't save \(v) to your block list."
                return false
            }
            kai_audit("kai", "block", "note", "app_rule", "Blocked sites: added \(v) for every agent")
        } else {
            guard kai_egress_entry_valid(v) == 1 else {
                lastError = "“\(raw)” isn't a site name, address or range."
                return false
            }
            model.add("egress_block", v)
        }
        refresh(policy: model.policy)
        if InternetMode.current == .watch && InternetMode.blocklistOffered
            && !UserDefaults.standard.bool(forKey: Self.askedKey) {
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            offerTurnOn = true
        }
        return true
    }

    /// Lifting a block loosens protection: the owner confirms it (as for
    /// every other loosening change), then Kai records it.
    func remove(_ e: Entry, model: AppModel) {
        lastError = nil
        if e.fromPolicy {
            model.remove("egress_block", e.value)   // the policy engine holds it for the owner's OK
            refresh(policy: model.policy)
            return
        }
        Task {
            guard await OwnerAuth.shared.confirm("unblock \(e.value)") else { return }
            removeConfirmed(e, model: model)
        }
    }

    private func removeConfirmed(_ e: Entry, model: AppModel) {
        if kai_agent_block_remove(e.agent, e.value) == 0 {
            kai_audit("kai", "unblock", "note", "app_rule", "Blocked sites: removed \(e.value) for \(e.agentWords.lowercased())")
        } else {
            lastError = "Kai couldn't remove \(e.value)."
        }
        refresh(policy: model.policy)
    }

    /// Unblock a site from a Stopped connection (every rule that covers it).
    func unblock(_ host: String, model: AppModel) {
        for e in entries where BlockStarter.covers([e.value], host) || e.value == host { remove(e, model: model) }
    }
}

#if DEBUG
extension BlockList {
    func loadFixture(_ e: [Entry]) { entries = e; starterOffered = true }
}
#endif
