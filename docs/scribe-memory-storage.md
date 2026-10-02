# Compose persistent-memory storage ownership

This is an implementation foundation, not a complete memory feature. Cadence now
has exact Compose voice commands to save, inspect, correct, and forget facts for
verified saved TextEdit documents, but no broader conversation workflow.
The installed app is unchanged. Tests use synthetic records in temporary
directories and an in-memory Security backend; they do not create host Keychain keys.

A separate, default-off durable-memory consent policy now exists. It requires
an accepted disclosure revision and a TextEdit choice before issuing local
capture and retention grants, with a proposed 30-day maximum and no cloud
transmission grant. The consent controller itself performs no storage or
Keychain work. The retention period and backup limits are disclosed in a
separate Settings preview confirmation. The preview
rollout gate is off by default.

`ComposePersistentMemoryRuntime` owns the encrypted domain. It requires explicit
confirmed activation before creating a namespace or Keychain key, then requires
a separate confirmed proposal for each saved
fact. Reads and forgets require the current verified document action. A
synthetic end-to-end test confirms encrypted save, reopening, other-document
isolation, durable forget, conservative correction with lineage, and
stale-action callback protection. AppModel now constructs this owner inertly,
reopens only a previously confirmed domain while the separate rollout gate and
consent remain on, and exposes confirmation-based activation and global deletion
in Settings. The exact phrase “Cadence, remember for later that …” prepares one
fact only after verifying the current document action. Other exact phrases
inspect saved facts, propose a correction naming the old and new fact, or propose
forgetting all current facts for that document. The writing provider is skipped.
Visible Save, correction, and forget actions must confirm the same proposal
before the encrypted store changes. A forget proposal includes a revision token:
a new save after review makes its confirmation stale and preserves the newer
records. Cancellation or a stale action cannot save.
Another default-off setting permits relevant explicit saved facts in a local
Apple Intelligence draft for the same verified document. The spoken request
selects at most six facts within an 8,192-byte budget. A cloud destination
receives none. The coordinator pins IDs, text, and local-use revision for the
draft and re-reads the same scope before publication, Copy, and Insert. A
changed or forgotten fact invalidates the draft; fact-backed drafts do not
enter ordinary Compose history. The current inspector shows the exact saved
facts used by the draft. From review, the user can discard the draft and
regenerate from the same speech without all facts or one selected fact. The
replacement action revalidates the pinned document without capturing whichever
control has focus; repeated omissions compound across session and saved facts.
An exact duplicate in both stores is omitted from both. These controls do not
delete stored facts. Changed document identity or facts stop the replacement
before provider dispatch. This path has focused synthetic tests, but has not
been certified against an installed app and real TextEdit focus transitions.
Forgetting also clears the active memory action, so a delayed callback cannot
prepare a new save in the same recording after deletion. Provider results are
published only while the pinned saved-fact snapshot still matches.

## Stable identity across restarts

`ScribePersistentMemoryDomainStore` owns a versioned `namespace.json` beside
`memory.json`. The namespace contains the app bundle identifier, installation UUID,
storage-domain UUID and a hash binding the encrypted file's standardized path.
It contains no transcript, source text, memory record, key bytes or raw file path.
Debug and Release bundle identifiers remain separate domains.

Constructing the owner does no IO. `load()` reads without creating directories or
files. `create(authority:)` requires explicit confirmation before any IO and uses
the encrypted file's exclusive lock. It atomically persists identifiers and reads
them back before returning them. Repeated creation reuses a valid existing domain.
It never creates or rotates a key as a side effect.

`makeKeyStore(for:)` rechecks the persisted domain before constructing the existing
Keychain key store. Construction does not contact Keychain. Key provisioning still
requires its separate explicit authority and refuses any existing encrypted data.
Normal reopening reads the existing key; it does not call provisioning again.
The encrypted memory store then applies its own scoped identity, retention policy,
record confirmation, authentication and lifecycle checks.

## Failure and recovery boundaries

Missing namespace metadata beside any existing encrypted file is an orphaned-store
error. Empty, malformed, oversized, future-version and symlink metadata are preserved;
none triggers replacement identifiers. A copied namespace at a different path or
under a different app bundle is rejected. Lock contention returns a bounded busy
error. A failed atomic write does not return an unpersisted domain for key creation.

An old domain cannot be used to construct another key store after its namespace
has changed or disappeared. The factory is not a live revocation monitor for key
store objects already handed out. Future runtime reset/teardown must invalidate
active reads, saves and provider callbacks before releasing or changing domains.
No reset, automatic repair, relocation migration or Keychain cleanup is introduced
by this owner. A missing namespace cannot recover the identifiers of a surviving
Keychain item by guessing or scanning unrelated items.

Namespace existence does not grant capture or retention permission. The integration
test disables policy after reopening and verifies that retrieval stops before
another Keychain query. Nothing mines Dictation history or meeting storage.

## Verification

Native tests use the production domain owner, file-lock/atomic-file boundary,
Keychain lifecycle and encrypted store. They verify restart identity and decryption
of an explicitly confirmed synthetic record, preservation of existing ciphertext,
read-only absence, missing/corrupt/future metadata, app/path isolation, stale factory
requests, held locks, symlinks, bounded reads and interrupted writes. Host Security
calls are replaced with an in-memory test backend.

The latest native count and logs are in [the roadmap ledger](compose-roadmap-progress.md).
Signed-app Keychain behavior, live Settings and voice-proposal interaction,
per-document voice inspect/correct/forget, dependent-draft invalidation and
conversation adapter certification remain separate gates. Forget cannot
promise removal from external backups or already completed remote requests.


## Lifecycle-controlled expiry maintenance

`ScribePersistentMemoryMaintenance` is an inactive-by-default driver around the
existing encrypted-store expiry transaction. Explicit `start()` checks the owner's
live authorization, runs an initial expiry pass, and then schedules one pass per
60 seconds. Construction and denied activation install no task and perform no IO.
`ComposePersistentMemoryRuntime` starts it after confirmed activation or
reopening. AppModel only reopens a previously confirmed store when the separate
rollout gate is enabled; constructing the owner alone starts no task.

The runtime owner passes current authorization and calls `stop()` when memory
is disabled or its store is replaced. Stop cancels
the timer and invalidates pending store operations before notifying consumers.
Authorization is also checked at each wake. Generation identity and cancellation
checks prevent an old delayed wake from running after stop or restart. Stop returns
the cancelled task for callers that need to await teardown; ordinary callers need
not block on it.

An unchanged expiry pass sends no invalidation callback. Removed records invalidate
pending memory use and notify the consumer so dependent drafts can be cancelled.
The callback carries no text, identifiers or record counts. Lock contention makes
one attempt per scheduled interval. Other failures stop the driver, retain a coarse
unavailable status and require explicit restart; they never repair files or keys.

Tests exercise both deterministic timer boundaries and the real encrypted store's
expiry transaction, including durable removal and invalidation of pending reads and
saves. A synthetic runtime integration test verifies initial purge after reopening
and closure on consent disable. No production background task was activated;
connecting invalidation to future dependent drafts remains AppModel work.
