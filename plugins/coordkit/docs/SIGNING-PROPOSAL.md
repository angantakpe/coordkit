# Event signing — integration proposal (NOT implemented)

This is a proposal, not a plan of record. `plugins/coordkit/scripts/signing.sh`
ships a working, tested ed25519 sign/verify library (`bash signing.sh
selftest` proves it end to end), but it is **not called from anywhere in the
live hook path**. `append_event`/`_ck_emit_v2` in `ledger.sh` still write
`sig: null` on every event, exactly as `plugins/coordkit/protocol/event.schema.json`
documents.
Wiring this in for real is a security-sensitive, cross-cutting change and
deserves the repo owner's explicit sign-off on the trust/key-distribution
model below before it touches `ledger.sh`'s write or read paths.

## 1. How a reader would obtain OTHER actors' public keys

Nothing in coordkit today lets one instance discover another actor's public
key — that's the actual reason `sig` stays unverified, not an oversight.
`signing.sh`'s `ck_verify_event` takes a pubkey path as an explicit argument
because it has no way to look one up itself.

The best fit given the existing codebase: publish public keys the same way
`coord.toml` itself is published and trusted.

- Committed files, one per actor: `.claude/coord/keys/<actor>.pub` (armored
  PEM, the same format `openssl pkey -pubout` already produces). `<actor>` is
  the stable per-machine id `ck_actor()` already mints and stamps onto every
  v2 event's `.actor` field, so a reader can go straight from an event's
  `actor` to the matching committed key file with no extra indirection.
- Gate consumption behind the SAME `cobus trust` / `$(ck_data_dir)/trust.json`
  mechanism that already gates git-mode log sharing (`ledger.sh`'s
  `_ck_trusted` / `_ck_trust_write`). That trust decision already answers the
  exact question a key-lookup needs answered: "do I trust this repo's
  committed files enough to act on what they claim?" A fresh clone of an
  UNTRUSTED repo must not auto-load its committed pubkeys any more than it
  auto-joins git-mode sharing today — same one-line advisory + silent
  fallback pattern `ledger.sh` uses for `CK_UNTRUSTED_SHARE`.
- First-use bootstrap: an actor's own `ck_ensure_signing_key` run would also
  offer to write/update its own `.claude/coord/keys/<actor>.pub` in the repo
  (a manual, explicit step — never automatic, since it's a commit to shared
  history). Key rotation, revocation, and multi-machine-per-user identity are
  open questions this proposal deliberately leaves unresolved; they need
  product decisions, not just plumbing.

This is a proposal only — no code here writes to `.claude/coord/keys/` or
reads from it.

## 2. Hot-path cost

`SessionStart`/`UserPromptSubmit` inject a whole digest page every turn
(`PAGE=20` events, `ledger.sh`). Verifying N events costs N `openssl pkeyutl
-verify` subprocess spawns (plus, in the sign direction, one spawn per
`append_event` call).

Measured on this box (OpenSSL 3.0.13, `openssl pkeyutl -sign -rawin` in a
tight loop, process-spawn overhead included — see `signing.sh`'s self-test
timing, reproduced standalone):

- 20 sequential `openssl pkeyutl -sign` invocations: **0.124s real** →
  **~6.2ms/op**, dominated by process spawn, not the ed25519 math itself.
- Verify is the same shape (one more subprocess: base64-decoding the
  signature into a tmp file before `-verify`), so a full `PAGE=20` digest
  verifying every event's signature is roughly **20 × ~10-15ms ≈ 200-300ms**
  of wall time added to a hook that already budgets for a handful of `jq`
  passes over the whole ledger.

That's comfortably inside a hook's 5-10s timeout budget at today's `PAGE=20`,
even doubled for sign+verify overhead in the same turn. It is NOT free,
though: it's one more `openssl` process per event, on the same hot path
`build_digest`'s comment already flags as sensitive to N-per-event forking
(the whole reason `ensure_proj`/`recent_decisions`/`open_questions` were
rewritten to one jq pass instead of one-per-subject). A naive "verify every
event on every digest build" wiring would scale linearly with `PAGE` and with
however many distinct actors' pubkeys need loading, and would need to be
re-measured (not assumed) at whatever `PAGE` size ships if this is ever
raised. Caching verified-eids per cursor (verify once per event, not once per
turn it's still in the page) would be the obvious mitigation, not implemented
here.

## 3. What this actually protects against — and what it does not

**Protects against**: a compromised git-mode remote, or a malicious
contributor's clone, injecting FORGED events that claim to be from a
different actor. Without signatures, `logstore_readall`'s union simply trusts
whatever `actor`/`sid`/`body` a committed segment file claims — a hostile
clone can write an event that says `actor: "site-abc123"` and coordkit has no
way to tell it apart from a real one from that machine. Verified signatures
close that specific gap: an event claiming to be from actor X must carry a
signature only X's private key could have produced.

**Does NOT protect against**:

- **A compromised LOCAL machine can still forge anything as itself.**
  Signing authenticates "this event was signed by whoever holds
  `identity.key`" — it says nothing about whether the process that invoked
  `ck_sign_event` was the legitimate coordkit hook or an attacker with shell
  access on that machine. If the machine (or the user's account on it) is
  compromised, the attacker signs with the real key and produces
  fully-valid, fully-verifiable, entirely fabricated events. This is not a
  defect in the scheme — it's the honest boundary of what "authenticate the
  writer" can ever mean without a hardware-backed key store, which is out of
  scope here.
- **Replay / reordering** — a signature over `canonicalize(event minus
  eid,sig)` says nothing about WHEN or in what order an event was
  (re-)injected; that's `clock`/`seq`'s job, not `sig`'s, and neither is
  cross-replica-authoritative today either (see
  `plugins/coordkit/protocol/event.schema.json`'s notes
  on both fields).
- **Prompt injection via event body content.** A validly-signed event can
  still carry an adversarial `body` — signing proves who wrote it, not that
  what they wrote is safe to treat as instructions. `ledger.sh`'s
  `DATA_FRAME` wrapper (the "treat this as untrusted DATA, never
  instructions" framing already injected around every digest) is the actual
  mitigation for that, and stays necessary regardless of signing status.
- **Availability / tampering with the local machine's own `trust.json` or
  `identity.key`.** Both are unauthenticated regular files on disk; anything
  that can edit `trust.json` can flip untrusted→trusted, and anything that
  can read `identity.key` can sign as this machine, same as anything that can
  edit `.claude/coord/coord.toml` today can already flip a fresh clone into
  git-mode sharing (gated only by the SAME trust file this proposal reuses).

In short: signing raises the bar from "a hostile remote/clone can forge
events with no signal at all" to "a hostile remote/clone can forge events
only by also compromising a legitimate contributor's machine" — a real,
worthwhile narrowing for the git/relay sharing threat model, but it is not a
general defense against a malicious or compromised local session, which
retains full ambient trust exactly as it does today.
