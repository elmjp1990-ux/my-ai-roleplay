# Supabase drafts — initial classification

Last reviewed: 2026-11-15  
Scope: first-pass source classification from the repository-visible draft files and their in-file status notes. This is **not** a migration-ledger reconciliation and does not authorize execution, promotion, deletion, hosted DDL/DML, worker scheduling, or deployment.

## Rules

1. Files under this directory are not active migrations unless a separately reviewed, uniquely versioned file is added under `supabase/migrations/`.
2. Replay scripts and fixture SQL are disposable-only. Never run them against the hosted Supabase project.
3. Historical evidence may describe an older branch, schema snapshot or test-project state. Check its recorded commit/date before relying on it.
4. Do not delete or promote a file solely because a newer implementation exists. Verify all references and migration history first.
5. The repository has a previously recorded migration-ledger/source drift and timestamp-collision finding (see `migration-ledger-repository-manifest-2026-11-02.md`). That 2026-11-02 inventory is historical evidence, not a current ledger snapshot.

## Confirmed superseded / obsolete proposals

| File | Classification | Reason / handling |
|---|---|---|
| `character-turn-count-parent-delete-filter-proposal.sql` | Superseded | Its own header says not to promote independently; use the comprehensive cumulative-turn proposal instead. Retain as historical decision evidence until references are checked. |
| `chat-turn-stale-reconciliation.sql` | Obsolete design; revalidation required | Its own safety condition assumes a demo-only chat-turn without an external provider. The current Story flow uses a real provider, so do not schedule or apply this draft. Keep until all references are checked. |

## Active proposals — review and disposable replay required

| File | Classification | Handling |
|---|---|---|
| `chat-deletion-cumulative-turn-statistics-proposal.sql` | Active proposal | The current comprehensive proposal for preserving per-character turn counts across soft-delete and purge. Still blocked on migration provenance and exact local Supabase CLI replay. |
| `account-deletion-character-preservation-draft.sql` | Active proposal | Account/character preservation changes; never apply to hosted Supabase without a separate approval and disposable tests. |
| `encounter-session-delete-lifecycle-guards.sql` | Active proposal | Encounter/session deletion lifecycle guards; migration provenance and local replay remain prerequisites. |
| `chat-deletion-purge-cron.sql` | Operational draft | Do not schedule until the exact deployed worker, authentication, retries and acceptance evidence are approved. |
| `character-history-aware-deletion.sql` | Active proposal | Character deletion and Storage cleanup; requires full migration and foreign-key review plus disposable replay. |
| `chat-turn-assistant-update-guard.sql` | Security proposal / test-only candidate | Review against current chat-message write paths and triggers before any promotion. |
| `chat-turn-validation-matrix.md` | Test specification | Describes a test plan; its own header says tests have not been executed. |

## Replay fixtures and test harnesses — disposable-only

| File | Classification | Handling |
|---|---|---|
| `replay-local-security-drafts.sql` | Replay harness | Transactional local replay only; not a release migration. |
| `replay-account-deletion-release-migration.sql` | Replay harness | Local fixture/replay script; do not run on hosted databases. |
| `replay-deletion-concurrency-setup.sql` | Concurrency fixture | Synthetic users and rollback/disposable database only. |
| `replay-and-test-character-deletion.sql` | Replay harness | Disposable-only; includes draft SQL and fixture setup. |
| `verify-deletion-draft-replay.sql`, `verify-deletion-draft-rollback.sql` | Verification fixtures | Assertions for disposable replay/rollback; not migrations. |
| `disposable-platform-bootstrap.sql`, `verify-current-state-schema-fixture.sql` | Synthetic platform/schema fixtures | Test scaffolding only; not a reconstruction of the full historical migration chain. |
| `legacy-image-migration-rpcs.sql` | Integration-test RPC fixture | Service-role-only test RPCs; explicitly not for hosted Supabase. |

## Evidence, audit and design records

| File | Classification | Handling |
|---|---|---|
| `current-state-schema-catalog-manifest-2026-11-02.md` | Schema evidence snapshot | Disposable/test-project catalog snapshot; date-bound, no application rows. |
| `pr200-migration-security-review-2026-11-03.md` | Security/migration audit evidence | Historical read-only review; refresh against current main and current hosted ledger before decisions. |
| `migration-ledger-repository-manifest-2026-11-02.md` | Migration provenance evidence | Historical record of ledger/repository drift and collisions; do not treat as current truth without a fresh comparison. |
| `migration-version-collision-replay-hazard-2026-11-01.md` | Migration risk analysis | Historical source-provenance warning; retain until the current full ledger comparison is completed. |
| `characters-baseline-provenance-2026-11-02.md`, `synthetic-disposable-baseline-design-2026-11-02.md` | Schema provenance/design | Explains baseline reconstruction limits; not a migration source. |
| `chat-deletion-lifecycle-reconciliation.md`, `chat-deletion-sql-writer-path-inventory-2026-11-02.md` | Lifecycle/source audit | Evidence and implementation notes; verify commit/date before reuse. |
| `live-nsfw-turn-count-gate-provenance-2026-11-01.md`, `character-turn-count-migration-provenance-2026-11-01.md` | Behavior/provenance evidence | Historical findings; the latter explicitly points to the cumulative-turn proposal as the current proposal. |
| `pr200-runtime-and-migration-status-2026-11-03.md`, `chat-deletion-final-acceptance-2026-11-01.md`, `chat-deletion-worker-runbook-2026-11-01.md` | Runtime/test evidence | PR- and deployment-specific records; not proof of current deployment state. |
| `account-deletion-worker-concurrency-audit-2026-11-02.md`, `account-deletion-worker-atomic-lease-design-2026-11-02.md`, `account-deletion-character-preservation-policy-review-2026-11-02.md` | Security/design evidence | Keep separate from deployable migrations; account-deletion execution remains subject to its kill switch and dedicated acceptance. |
| `character-profile-organization-queue-design-2026-11-07.md` | AI-profile design/evidence | Reference for the derived-profile queue; check current implementation and tests before editing. |
| `chat-message-write-guard-tests.md`, `chat-deletion-retention-matrix-2026-11-01.md`, `chat-deletion-access-control-matrix-2026-11-01.md` | Test/design specifications | Not executable release SQL; reconcile with current behavior and test evidence. |

## Historical reference — not a deployment source

| File | Classification | Handling |
|---|---|---|
| `chat-turn-wallet-charging.sql` | Historical SQL reference | Its header says the equivalent SQL was applied through the 2026-10-15 wallet migration. Keep as reference only; wallet changes are outside this refactor batch. |
| `group-chat-core-schema.sql` | Pre-implementation group schema proposal | The live implementation is now represented by later migration sources and Edge Functions. Compare before marking superseded; do not execute this draft. |

## Not yet classified

This is a first-pass index, not a claim that every file in this directory has been exhaustively reviewed. Any file not listed above remains **unclassified / retain**. The next full inventory must enumerate the directory from the Git tree, inspect all inbound references, and record its exact source commit and status before deletion or promotion.
