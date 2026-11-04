# PR #200 follow-up — Storage retry verification and migration reconciliation plan

Date: 2026-11-01
Repository: `elmjp1990-ux/my-ai-roleplay`
Branch: `security/chat-deletion-lifecycle-reconciliation`
Test project: `ouyewoagbmtqehbofrje`
Status: planning / read-only review only. No schema, data, deployment, schedule, or migration-history changes.

## 1. Current verified baseline

- Worker `purge-chat-deletions` is ACTIVE version 9 in the test project.
- User completed the post-v9 Dashboard POST smoke test: `ok: true`; all six summary counters were zero.
- Read-only queue check after the invocation: no non-completed chat jobs, zero Storage jobs, and one previously documented completed synthetic parent tombstone.
- PR #200 remains Draft and unmerged. No chat-deletion cron exists. PR #201 remains paused.
- Live migration inventory currently contains 151 entries (141 historical entries plus 10 PR #200 migrations).
- The pre-PR repository inventory had 96 SQL migration files; PR #200 adds 10, for 106 files in this branch.
- Existing inventory comparison recorded 67 shared names with different timestamp prefixes, 57 live-only names, 14 repository-only names, duplicate repository prefixes, five legacy filenames without unique 14-digit versions, and two historical chat-deletion SQL sources not found in GitHub history.
- The branch includes duplicate prefix `20261015151500` (at least two files); the inventory also records duplicate prefixes later in the history. A filename-only replay cannot safely be assumed.

## 2. Storage API failure → retry: safe verification decision

### What is already proven

- Actual disposable PNG objects for single and group chat were removed through the real Supabase Storage API by the Worker.
- Missing-object handling completed idempotently.
- Queue claim/failure RPCs for both queue types passed rollback-only database tests, including retry/backoff through attempts 1–7 and dead-letter at attempt 8.
- Worker v9 requires the Storage completion RPC to return exactly `true` before incrementing `storage_deleted`; transport errors and false completion results are not reported as success.
- The Worker source routes a Storage remove error to `mark_chat_storage_deletion_job(p_success: false, ...)`.

### What is not proven

A real Supabase Storage HTTP error has not been induced and observed flowing through the deployed Worker into a durable retry. The Storage API exposes no supported request-level fault-injection parameter in the reviewed interface. A missing object is a successful/idempotent outcome, and malformed/traversal-shaped paths are not a reliable error stimulus. Supabase-managed `storage` schema triggers/policies must not be modified to manufacture a failure.

### Recommended no-cost test improvement

1. Refactor only if needed to isolate the Storage-removal operation behind a small internal dependency/adapter used by the Worker processor. Keep the deployed production adapter calling the same Supabase Storage SDK `remove()`; do not add a public test endpoint, secret override, alternate bucket, or runtime bypass.
2. Add Deno unit tests with a fake adapter that deterministically returns a Storage error (e.g. simulated 5xx/network failure) and a fake/rollback-backed queue RPC interface. Assert:
   - `mark_chat_storage_deletion_job` receives `p_success: false` and a sanitized error code;
   - the failure counter increments and the success counter does not;
   - the queue state transitions to retry with a future `next_attempt_at`;
   - at the configured final attempt it transitions to `dead_letter`;
   - a later successful adapter result completes the job;
   - `marked === false` is never counted as success.
3. Run database state-machine assertions inside explicit rollback transactions; leave no queue fixtures.
4. Label this evidence accurately as deterministic Worker/queue integration testing with a simulated Storage failure. It does **not** prove Supabase's live Storage service returns that error shape.
5. Keep the live Storage API error E2E as an explicit external validation limitation unless Supabase supplies a supported isolated fault-injection mechanism or a naturally occurring isolated service failure can be safely observed. Do not induce a project-wide outage and do not touch managed `storage` objects/triggers.

No Worker code change is made by this plan. The adapter seam and tests should be a separate reviewed commit before deciding whether this remaining external limitation is an acceptable residual risk.

## 3. Migration history reconciliation: no-cost, non-destructive plan

### Hard safety boundaries

- Do not run `supabase db reset`, `db push`, `migration repair`, `migration down`, or any migration-writing command against the existing hosted test project.
- Do not edit `supabase_migrations.schema_migrations` manually.
- Do not rename/rewrite historical migration files merely to make timestamps line up.
- Do not fabricate the missing historical SQL sources.
- Do not create a Supabase Cloud branch or paid disposable project without a separate cost decision. The user requested use of existing resources/no additional spend.
- Do not treat a schema-only snapshot as a complete replacement for data migrations, Storage buckets/policies, extensions, cron jobs, Vault secrets, or other platform configuration.

### Phase A — freeze evidence (read-only)

1. Pin the exact source commit and PR head used for the baseline.
2. Export/read the complete remote migration list and repository migration file list.
3. Produce a collision report by 14-digit prefix and a name/version mapping report.
4. Capture a read-only schema inventory from the existing test project: schemas, tables/columns/defaults, constraints/FKs, indexes, triggers, policies, function definitions/security settings/grants, views, extensions, Storage buckets/policies, and cron jobs.
5. Hash and retain each snapshot with timestamp and project ref. Do not include secret values or user content.

### Phase B — source provenance

1. For each live-only migration, identify whether its effect exists in current repository SQL, another commit/PR, a manual Dashboard change, or an unavailable historical source.
2. For each repository-only migration, determine whether its effect is absent, superseded, renamed, or already present in the live schema.
3. Review the two historical chat deletion SQL functions whose source files were not found in GitHub history; compare their current live definitions with the current replacement implementation.
4. Do not mark a migration applied/reverted based only on its name or timestamp. Require object-level evidence that its SQL effects are already present or absent.

### Phase C — local clean-room replay (no hosted branch)

1. Use a separate disposable local checkout/worktree and a local Postgres/Supabase CLI stack only if local Docker resources are already available; this avoids creating a billable Supabase Cloud branch.
2. First run inventory/static checks only. Confirm unique migration versions and all required source files before attempting replay.
3. Attempt replay only in the disposable local database. Record the first exact failure and stop; do not auto-repair history or skip migrations to force a green result.
4. If the historical chain cannot replay, stop treating the historical directory as a reliable clean-install chain. Do not spend time repeatedly retrying the same broken replay.

### Phase D — if historical replay is not recoverable

1. Create a separately reviewed canonical baseline from the authoritative live schema snapshot, preserving object ownership, grants, RLS, functions, triggers, and required extensions.
2. Explicitly supplement objects/configuration that schema dumps may omit or that are data-driven: seed/reference data, Storage buckets and policies, cron definitions, Vault secret *names/references only*, and required platform settings. Never export secret values.
3. Build a new clean-install migration path from that baseline, then append only newly reviewed migrations. Keep the current hosted test database untouched while this path is tested locally.
4. Compare the reconstructed local schema object-by-object against the frozen live snapshot. Require zero unexplained differences in security-critical objects before considering it a valid baseline.
5. Only after a reviewed clean-room replay passes should a separate, explicit deployment plan be considered for existing environments. No remote history repair is implied by this document.

## 4. Decision gates

| Gate | Current status | Exit evidence |
|---|---|---|
| Worker v9 runtime smoke | PASS | Dashboard returned `ok: true`; six counters zero; read-only queues clean |
| Actual Storage upload/remove | PASS | Disposable single/group PNGs removed through Storage API |
| Missing-object idempotency | PASS | Live Worker completed missing legal object path |
| DB retry/backoff/dead-letter | PASS — rollback-only | Both queue state machines tested through attempt 8 |
| Live Storage HTTP error → retry | NOT VERIFIED | Supported fault injection or isolated real Storage failure observed end-to-end |
| Deterministic Worker adapter failure tests | NOT YET IMPLEMENTED | Tests assert sanitized failure routing, retry/dead-letter, and success accounting |
| Migration inventory | PASS — read-only | 151 live entries and branch file inventory reconciled against prior baseline |
| Migration clean-room replay | NOT STARTED | Disposable local replay with exact failure/success evidence |
| PR #200 merge | BLOCKED | User approval plus explicit disposition of remaining verification and migration gates |
| Chat deletion cron | DISABLED | Requires separate explicit user approval after all gates |
| PR #201 account deletion | PAUSED | Separate group-charge archive, orphan content, and bucket-specific Storage sweep design |

## 5. Immediate next implementation sequence

1. Add a narrowly scoped Worker processor test seam and deterministic Deno tests for simulated Storage failure, retry, dead-letter, later success, and false completion RPC results. Do not alter the production Storage bucket or deployed auth path.
2. Perform Phase A migration snapshot/provenance work using read-only tools and repository artifacts.
3. If local Docker is already available, perform Phase C in a disposable local environment; otherwise stop at a documented static inventory and do not create a paid cloud branch.
4. Update this plan and Notion with actual test outputs before changing PR status.

This document is a plan and risk record, not approval to merge, schedule, alter migration history, or touch production.
