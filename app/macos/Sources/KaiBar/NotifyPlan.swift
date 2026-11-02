// SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-Kai-Commercial
//
// Which notifications to post (dogfood, Nov 1): one per waiting card per agent
// and host, never folded into another host. A repeat card for a host still
// waiting doesn't notify again; once you answer, the next card does. Foundation
// only, so tests/app/notify_main.swift compiles it on its own.
import Foundation

struct NotifyPlan {
    struct Card: Equatable {
        let id: String
        let agent: String
        let host: String
    }

    /// agent|host -> when its notification was posted, while its card waits.
    private var waiting: [String: Date] = [:]
    private var seen: Set<String> = []

    /// The notification id for one agent and host: a repeat replaces it.
    static func cardID(agent: String, host: String) -> String { "kai.card.\(agent)|\(host.lowercased())" }

    /// A block banner's key: agent, reason and target, so two files or two
    /// hosts never fold into one banner.
    static func blockKey(agent: String, rule: String, target: String) -> String { "\(agent)|\(rule)|\(target)" }

    /// The cards to notify now, from the cards currently waiting.
    mutating func cardsToNotify(_ cards: [Card], now: Date = Date()) -> [Card] {
        var out: [Card] = []
        for c in cards where !seen.contains(c.id) {
            seen.insert(c.id)
            let key = Self.cardID(agent: c.agent, host: c.host)
            if waiting[key] != nil { continue }   // that host is already waiting for you
            waiting[key] = now
            out.append(c)
        }
        // a host whose cards are all gone is no longer waiting
        let live = Set(cards.map { Self.cardID(agent: $0.agent, host: $0.host) })
        for k in waiting.keys where !live.contains(k) && !out.contains(where: { Self.cardID(agent: $0.agent, host: $0.host) == k }) {
            waiting[k] = nil
        }
        return out
    }

    /// You answered (from the card or the notification): the next card notifies.
    mutating func answered(agent: String, host: String) { waiting[Self.cardID(agent: agent, host: host)] = nil }
}
