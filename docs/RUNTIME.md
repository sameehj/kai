# Runtime enforcement health (B4)

Kai reports two things separately, in `kai doctor` and in the app:

- **Extension health**: is each extension running, is its heartbeat fresh (30 s at most; root-owned, not writable by agents), and does it run the current policy (the heartbeat carries the policy's fingerprint, the first 12 hex digits of its SHA-256).
- **Enforcement coverage**: which agent work it actually attributes and checks. Files: how many of the running agent sessions it has attributed (an unattributed process gets no session permissions). Internet: how many agent connections it has seen and blocked since it started. "0 seen" means nothing has been measured yet, not that everything is checked.

## When something fails

Nothing here claims fail-closed without live evidence. Every row says how we know.

| Event | What is enforced meanwhile | What Kai shows | Evidence |
|---|---|---|---|
| Files extension restarting or crashed | Nothing from Files. Agent checks (hooks) still run inside each agent. **Fail-open.** | Status loses the Files heartbeat within 30 s: "Files: not running". | Heartbeat expiry: unit tests. The gap itself: **not measured live yet**. |
| Internet extension restarting or crashed | Nothing from Internet. macOS lets flows through while no filter is running. **Fail-open.** | "Internet: not running" once the heartbeat is 30 s old. | **Not measured live yet** (Gate B2). |
| Endpoint Security deadline missed (Files too slow to answer) | macOS ends the client and lets the event through. **Fail-open** for that event and until Files restarts. | As for a crash. | Apple's documented behaviour. **Not measured live yet.** |
| Policy reload under load | The last good policy stays in force until the new one loads; a policy that doesn't parse is never loaded. | Doctor: "policy not the current file yet" while a wall runs an older fingerprint. | Keep-last-good: unit tests. Under load: **not measured live yet**. |
| Kai paused (15 minutes) | Hooks and Files let soft blocks through and record them. Internet lets everything through and records nothing. Kai's own settings stay blocked. | Banner: "Kai is paused until HH:MM …". | Unit and hook tests. Live: **not measured yet**. |

## Revocation bound

How long after you press **Revoke** (or the grant expires) the next attempt is denied:

| Where | Bound | Why | Evidence |
|---|---|---|---|
| Agent checks (hooks): MCP tools, the only grants the hooks use | Next call | Grants are read from disk on every MCP call (`kai_mcp_request`). | Unit tests |
| Files | About 4 s | The store reloads every 2 s, debounced to 2 s. | Unit test (`revocation reaches a read-only store`). Live: **not measured yet**. |
| Internet | About 2 s after the next connection attempt | Reloaded on the next connection, debounced to 2 s. **A connection that is already open stays open**: macOS filters a flow when it starts. | Unit test as above. Live: **not measured yet**. |
| Rules and Keep blocked | Next attempt | Read from disk on every lookup. | Unit tests |

Fixed on 2026-10-28: before this, the extensions' stores reloaded only when the *newest* grant file changed. Revoking any older grant left the extension honouring it until another grant changed. The reload now watches the folder itself, every file and the count.

## Performance

CPU and latency with both extensions on under a large build: **not measured yet**. The Files extension has an opt-in profiler for its decision path (`kai_prof_*`, off by default).

## Not covered by these numbers

- A process Kai can't attribute to a session (for example, one detached by launchd) gets no session permissions. Doctor counts these as unattributed.
- Anything an agent does without a hook event and while an extension is down: see [ESCAPES.md](ESCAPES.md) and [COVERAGE.md](COVERAGE.md).

## QUIC (UDP 443)

QUIC carries the site name inside an encrypted packet, so Kai can't see it. For agent processes, the Internet extension drops QUIC in both Watch and Protect, with no card. The agent falls back to HTTPS over TCP, where Kai reads the site name (TLS SNI) and decides as usual. Each agent's QUIC drop is noted in the log as `log` at most every 10 minutes. It counts as a fallback, not a block. QUIC isn't dropped when Internet is Off or Kai is paused, or for an address on your allowed list. Non-agent apps are never touched.

Why this matters: before this, every QUIC connection (Cursor uses it a lot) became a "host unknown" card that couldn't be approved usefully. Evidence: code; **not yet measured live**.
