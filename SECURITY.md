# Security policy

Kai is a security tool, so a bug in Kai can be an attack path. Please report
vulnerabilities privately.

## Reporting

- **Do not** open a public GitHub issue for a vulnerability.
- Email **security@<domain>** (placeholder — set before launch), or use GitHub's
  "Report a vulnerability" private advisory flow on this repository.
- Include steps to reproduce, affected version/commit, and impact.

We aim to acknowledge within 3 business days and to ship a fix or mitigation for
confirmed high-severity issues promptly, coordinating disclosure with you.

## Scope

In scope: the `kai` binary, `libkai`, the hook handlers, the installer, and the
audit log. Especially valued:

- A way to get a secret value written into the audit log.
- A policy that parses but fails **open** (allows an action it should block).
- A path or command that bypasses a `protect` rule (traversal, symlink,
  encoding, quoting tricks).
- A prompt-injection string that defeats the detectors (we expect gaps here —
  reports help us measure and close them).
- Memory-safety bugs in the core (crashes, overflows).

## What Kai does not claim

v0.1 protects **Claude Code** and **Cursor** through their hooks. It does not yet
cover GUI chat apps, agents running on vendor servers, or apps Kai can't hook.
The hook layer can be bypassed by a sufficiently clever script; the OS-level
walls on the roadmap are what close that gap. These are documented limits, not
vulnerabilities — but a bypass that defeats a documented protection *is* in
scope.

## Safe harbor

We will not pursue legal action for good-faith security research that respects
users' privacy, avoids data destruction, and gives us reasonable time to fix
issues before public disclosure.
