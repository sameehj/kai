# Item 1 — SSH over the live wall: PASS

**Build:** storage ext **v26**, network ext **v14**, both `[activated enabled]`.
**State at test:** both walls `mode=block, enforcing=true` (storage + network
health snapshots fresh).

## Result
- `git ls-remote git@github.com:…` (reads `~/.ssh/known_hosts`): **succeeded**,
  zero cards.
- `git push git@github.com:… fix/approval-key-and-ux` over the live wall:
  completed the SSH handshake (read `known_hosts`, authenticated through
  ssh-agent, connected to GitHub) with **zero cards** and no
  "Operation not permitted". Private key file never opened (ssh-agent supplied
  it).

This is the Item-1 "done when": git over SSH works with both walls in Block,
private keys still protected, no prompts — because the public ssh files
(`known_hosts`, `config`, `*.pub`) are readable and the private key is served by
ssh-agent.

(Recorded live; this file's own push is the end-to-end write test.)
