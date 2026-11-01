# PR #200 — SQL writer-path inventory (bounded review, 2026-11-02)

Status: partial inventory; not a claim of repository-wide completeness.

## Scope inspected

- All SQL migration files changed by PR #200.
- Changed Edge Function files: `chat-deletion-worker.ts`, `purge-chat-deletions/index.ts`, `story-session/index.ts`.
- Frontend call sites in the PR branch `index.html`.
- The deployed single-chat `chat-turn` Edge Function fetched from the PR branch.
- Live test-project definition of `public.sync_character_chat_snapshot(uuid)`.

## Confirmed writer paths

| Path | Writes | Parent serialization / gate | Result |
|---|---|---|---|
| `append_chat_group_mock_turn` | group turn, player message, character reply, charge, wallet transactions | locks `chat_groups` FOR UPDATE; owner + active + not archived | Good for this writer |
| Frontend group edit/delete latest message | updates `chat_group_messages` | authenticated direct DML denied by grants; restrictive active-parent RLS | Requires transaction race fixture |
| `delete_chat_group_with_related_data` | soft-delete marker + deletion/storage jobs | locks group parent first | Deletion entry point |
| `delete_chat_session_content` | soft-delete marker + deletion/storage jobs | locks session parent first | Deletion entry point |
| `chat-turn` Edge Function | service-role assistant insert into `chat_messages` | calls `reserve_chat_turn`; assistant insert trigger locks session and checks active state | Single-chat late-write gate exists |
| `sync_character_chat_snapshot` | updates session snapshot, group member snapshot, group message speaker snapshot | live definition had no parent-first group lock and no deleted-parent filter | Gap; draft fix added |

## Confirmed gap and proposed fix

Live `sync_character_chat_snapshot(uuid)` is SECURITY DEFINER and updates group child metadata by character ID, including rows whose parent group has `deleted_at`. This bypasses the authenticated RLS lifecycle guard. Draft-only fix:

`supabase/drafts/sync-character-chat-snapshot-parent-lock-proposal.sql`

The proposal locks active single-session parents, then active group parents in deterministic ID order, and only updates children belonging to active parents. No migration has been applied.

## Limits

- This review covered PR changed SQL files, selected frontend call sites, and the named deployed Edge Function. It did not enumerate every unchanged repository migration, every live function, Dashboard SQL, external service-role integration, or manually invoked service-role query.
- service_role bypasses RLS. Do not revoke service_role table grants until every worker/function dependency is inventoried.
- The group mock writer is the only explicit `INSERT INTO chat_group_messages` found in the PR changed migrations. This does not prove no other writer exists outside that scope.
- No schema changes, data changes, Storage operations, deployment, cron, or production operations were performed.

## Required next work

1. Full repository-wide SQL function/trigger/view writer index, not only PR changed files.
2. Inventory all service_role callers and any direct DML to group tables.
3. Add transaction fixtures for writer/delete ordering and child edit/delete ordering.
4. Integrate immutable per-character turn snapshots into delete RPCs and the latest purge RPC; make count RPCs use active live rows plus archived snapshots exactly once.
5. Add rollback, idempotency, incomplete-snapshot detection, purge retry, and post-purge count-invariance tests.
6. Restore a trustworthy schema-only local baseline and pass clean replay before applying migrations anywhere.
7. Complete browser multi-tab/device and real Storage failure/retry E2E.

No cron, deployment, merge, or hosted DDL is authorized by this document.

## Fifth-round extension: historical migrations and character lifecycle writers

A targeted pass over the historical group-chat and character snapshot migrations found:

- `create_chat_group(...)` creates a new group/scenes/member snapshots atomically. It is a creation path, not a writer into an already deleted parent; its member-limit trigger locks the parent group before member insert/update.
- Historical definitions of `append_chat_group_mock_turn(...)` existed in 2026-10-15 migrations and were later replaced by billing and parent-first guard migrations. Do not assess only the earliest definition; the effective latest definition is in `20261101053732_chat_writer_parent_first_guards.sql`.
- `soft_delete_character(...)` in `20261022175412_sync_group_character_snapshots_on_delete_and_update.sql` is a second SECURITY DEFINER snapshot writer. It originally updates all chat sessions, group members, and group messages by character ID without locking chat parents or excluding deleted parents. Fixing only `sync_character_chat_snapshot` would leave this sibling bypass.
- The parent-lock proposal was expanded to replace both `soft_delete_character` and `sync_character_chat_snapshot`. Both paths now lock active single-chat parents and active group parents in deterministic order before child snapshot updates; deleted parents are skipped. Draft-only commit `e76edc374d872765fbea51d1fa938df4b860480c`.
- Encounter writer paths `reserve_encounter_chat_turn` and `record_encounter_session_turn_evidence` in `20261101054027_encounter_chat_deletion_gates.sql` both lock `chat_sessions` parent first and reject deleted parents before lifecycle/charge/evidence writes.
- Encounter interaction writer `record_encounter_turn_interaction` also reads the matching charge, then locks the session parent before locking charge and inserting receipt/affinity/diary evidence; it rejects deleted sessions.
- Encounter evaluation queue functions write evaluation jobs/lifecycle state, not chat transcript rows; their session-deletion interaction still needs explicit coverage in the dedicated queue/worker audit.

### Coverage status

The PR branch tree contains 107 migration files. This round inspected a targeted subset of historical group, character snapshot, encounter writer, and chat-deletion migrations; it did not fetch/review every one of the 107 migration bodies. Therefore the repository-wide writer inventory remains partial. Do not mark 5A fully complete.

## Encounter evaluation queue: deleted-session re-enqueue risk

Review of `20261031240000_encounter_evaluation_dispatch_queue.sql`, its bounded-retry replacement `20261031250000_bound_encounter_evaluation_retries.sql`, and the latest chat purge RPC found:

- `enqueue_due_encounter_evaluations()` locks/updates `encounter_session_lifecycle` and can enqueue a job based on lifecycle status/time, but does not join/check `chat_sessions.deleted_at` and does not lock the chat session parent first.
- `claim_encounter_evaluation_jobs()` also selects ready lifecycle/job rows without checking `chat_sessions.deleted_at`; it claims only the job row.
- Chat purge deletes `encounter_session_evaluation_jobs` and clears lifecycle payload fields, but does not transition the lifecycle status out of `active/paused/ready_to_settle`. The lifecycle row survives because it is the queue FK parent.
- Therefore, after chat purge deletes an evaluation job, the existing minute dispatcher can potentially enqueue it again from the surviving due lifecycle row. This is a real static lifecycle integration risk; no runtime race has yet been executed.
- Added draft-only proposal `supabase/drafts/encounter-evaluation-deletion-gate-proposal.sql` (commit `016e20389900443fdc34ffcee573e795d14832a6`). It joins/checks the chat parent, uses parent-first locking before lifecycle/job locks, and prevents enqueue/claim for deleted sessions. It preserves the existing service_role-only function ACL and does not add a chat-deletion Cron.
- Claim-time filtering is not enough by itself: the evaluator's final settlement RPC must also recheck and lock the chat session parent, because deletion can happen after a job is claimed. That path remains a required audit/test.

Required tests: purge-then-dispatch no re-enqueue; dispatcher-first vs delete-first lock ordering; claim skips deleted sessions; settlement rejects deleted sessions under parent lock; active-session retry/lease remains bounded.


## Seventh-round extension: Encounter settlement vs deletion (2026-11-02)

A cross-check of the queue-gate proposal against the existing draft `encounter-session-delete-lifecycle-guards.sql` found:

- The existing draft replacement for `settle_encounter_session(...)` already locks `chat_sessions` first with `deleted_at IS NULL`, then locks `encounter_session_lifecycle`, and only then updates `encounter_character_state` and lifecycle settlement fields. This is the correct serialization shape against chat deletion **if this draft is included and its ACL is preserved**.
- The settlement replacement is currently draft-only; it is not in the PR's changed migration list and has not been applied. It must not be described as an active protection.
- The queue-gate proposal separately fixes dispatcher and claimer parent locking. Both are required: queue filtering prevents deleted work from being enqueued/claimed, while settlement parent locking prevents an already-claimed worker from committing affinity after deletion wins the parent lock.
- The settlement draft shown in this file does not itself include explicit GRANT/REVOKE statements for `settle_encounter_session`. Before promotion, fetch the live function ACL and preserve its exact intended caller boundary. Do not assume that SECURITY DEFINER alone makes it service-only.
- The settlement RPC returns idempotently for an already-settled lifecycle only after the parent lock/check, which is desirable: a deleted parent cannot use the idempotent branch to reveal or mutate settlement state.
- The inspected settlement body checks pending pre-expiry reserved/reconciliation charges and evidence-count equality before applying affinity. It does not settle while there is incomplete turn evidence.

### Remaining evaluator integration evidence gap

The PR-changed Edge Function set contains the deletion worker and story-session function; it does not contain a dedicated Encounter evaluator file. This bounded pass has not yet established the deployed evaluator's exact function name, RPC call order, or failure/retry behavior. Trace the deployed evaluator entry point and confirm it calls `settle_encounter_session` only after a successful claim, and that failures use the bounded `fail_encounter_evaluation_job` path. Do not infer this from the queue SQL alone.

### Required combined race matrix

1. Evaluator claims first, then delete acquires `chat_sessions`: settlement must block, observe `deleted_at`, and reject without affinity/lifecycle mutation.
2. Settlement acquires `chat_sessions` first: deletion must wait; settlement may complete, then deletion proceeds and hides/purges the chat on its schedule.
3. Dispatcher claims/queues before delete: delete must remove the job; worker settlement must still reject if delete wins parent lock.
4. Delete/purge completes before dispatcher: no job may be recreated from surviving lifecycle rows.
5. Verify function ACL for settlement, enqueue, claim, and fail RPCs; verify evaluator service identity; verify retry count/lease is bounded.

Coverage remains partial; no runtime lock-race fixture or deployed evaluator trace has been completed in this round.


## Eighth-round extension: actual Encounter evaluator and queue ACL trace (2026-11-02)

Inspected the branch's complete `supabase/functions/` top-level directory and the concrete Encounter Edge Function entrypoints:

- Present: `encounter-session/index.ts` (create/reuse session), `encounter-session-state/index.ts` (pause/resume RPC), and `encounter-turn/index.ts` (demo reply, charge reservation/settlement, evidence persistence).
- Not present in the enumerated Edge Function directories: a dedicated Encounter evaluation worker/evaluator that claims `claim_encounter_evaluation_jobs`, obtains an AI evaluation, and calls `settle_encounter_session`.
- `encounter-turn` explicitly says demo response only; no real AI provider is connected. It records evidence with evaluator marker `pending` and returns `affinityPendingUntilSceneEnd: true`. This is not the whole-session evaluator and does not invoke `settle_encounter_session`.
- Consequently, the earlier evaluator claim/settle race is a future integration requirement, not a verified currently-running Edge Function path. The SQL queue schema and RPCs are scaffolding awaiting a trusted evaluator.

### Queue RPC ACL and retry facts from migrations

- `enqueue_due_encounter_evaluations(integer)`: explicitly REVOKE EXECUTE from PUBLIC/anon/authenticated and GRANT only to service_role.
- `claim_encounter_evaluation_jobs(integer)`: same service_role-only EXECUTE ACL.
- `fail_encounter_evaluation_job(uuid,text)`: same service_role-only EXECUTE ACL.
- Queue table: RLS enabled; table privileges revoked from PUBLIC/anon/authenticated; service_role CRUD granted.
- Retry bound: maximum 5 attempts; 10-minute processing lease; failed retry backoff 5 minutes. The dispatcher migration's first definition was later replaced by the bounded retry migration.
- The inspected migrations do not show an evaluator identity because no evaluator entrypoint was found in the function directory.

### Existing Encounter cron distinction

- `20261031240000_encounter_evaluation_dispatch_queue.sql` contains a pg_cron schedule named `poyozz-encounter-evaluation-dispatch` running every minute and calling `enqueue_due_encounter_evaluations(50)`.
- This is an Encounter evaluation *dispatcher* cron, not a chat-deletion purge cron. The user restriction against creating a chat-deletion cron remains respected; this audit did not create or modify any cron.
- This migration is in the repository branch. Static source inspection does not establish whether it has been applied to the test database; do not claim live cron state without a read-only catalog check.

### Corrected implementation sequencing

1. Treat the Encounter queue as currently incomplete scaffolding unless a deployed evaluator is found outside the enumerated repo Edge Functions.
2. Before implementing an evaluator, land/test the deleted-parent gate for enqueue/claim and the parent-first settlement replacement as a coordinated set; preserve the service_role-only ACLs for queue RPCs and inspect the live settlement ACL separately.
3. The future evaluator must use service_role, claim bounded batches, enforce the 5-attempt/10-minute lease/5-minute backoff, and call settlement only with trusted model output; settlement must independently lock/check the chat session parent.
4. Add tests for deleted-session dispatch/claim, job deletion/purge no-reenqueue, bounded retries, evaluator failure, and both lock acquisition orders.

This is static branch inventory only. It does not prove the test project's cron state, deployed Edge Function inventory, live function ACLs, or runtime behavior.


## Ninth-round extension: live test Supabase comparison (read-only, 2026-11-02)

This round queried the configured test project `ouyewoagbmtqehbofrje` using read-only catalog inspection and the Supabase project Edge Function/migration listings. No SQL writes, migration apply, deployment, or cron changes were performed.

### Live project state observed

- Applied migration history includes the Encounter queue migrations (`20261031011426`, `20261031011509`) and chat deletion lifecycle migrations through `20261101110211`. This establishes the project has recorded those migration versions; it does not establish every runtime behavior is correct.
- Active Edge Functions listed by the project include `encounter-session`, `encounter-turn`, `encounter-session-state`, `story-session`, and `purge-chat-deletions`; no Encounter evaluator/worker slug is deployed in the returned function list.
- Live cron catalog previously returned one active job: `poyozz-encounter-evaluation-dispatch`, every minute, DB user postgres. It calls the enqueue dispatcher. No chat-deletion purge cron appeared in that catalog result. This is the live Encounter dispatcher only; do not confuse it with deletion purge scheduling.
- Live `enqueue_due_encounter_evaluations(integer)` and `claim_encounter_evaluation_jobs(integer)` definitions already contain the deleted-parent gate and parent-first lock: select `chat_sessions` where `deleted_at IS NULL`, lock parent rows first with `FOR UPDATE ... SKIP LOCKED`, then lock lifecycle/job rows. This is stronger than the older migration source initially inspected and appears to be the later draft/proposal implementation already applied in the test DB.
- Live ACL inspection for enqueue/claim/fail showed owner postgres and EXECUTE granted to postgres and service_role only; no PUBLIC, anon, or authenticated EXECUTE.
- Live evaluation job table has RLS enabled and grants only to postgres and service_role; no anon/authenticated grants were observed.

### Critical live mismatch: settlement does not yet lock/check chat_sessions

The live `public.settle_encounter_session(uuid,integer,text,jsonb,jsonb)` definition was fetched read-only. It is SECURITY DEFINER, owned by postgres, and its body begins by locking `encounter_session_lifecycle` directly:

- It does **not** first lock `chat_sessions`.
- It does **not** check `chat_sessions.deleted_at IS NULL`.
- It returns the idempotent settled result before any deleted-parent check (because there is no parent check).
- It can proceed to update `encounter_character_state` affinity and lifecycle settlement after chat deletion if a valid call reaches it.
- Live ACL is restricted to postgres and service_role (no PUBLIC/anon/authenticated), which is good caller restriction but does not solve the deleted-parent lifecycle gap.

This is now a **confirmed live test-project static code finding**, not merely a draft concern. It is not a runtime-exploited finding: no race fixture or mutation was run. The existing draft replacement in `encounter-session-delete-lifecycle-guards.sql` contains the intended parent-first lock/check, but that replacement is not the live definition.

### Safe next action

- Do not execute the settlement replacement directly yet. First compare its exact signature/ACL with the live function and ensure it locks `chat_sessions` first, checks owner-independent deleted state, then locks lifecycle, and preserves idempotence only after the parent gate.
- Build a rollback-safe transaction test fixture in a disposable local database for both lock orders and for a deleted parent; verify no affinity/lifecycle writes occur when deleted.
- Only after tests pass, add a reviewed migration to PR #200; do not apply it to the hosted test project as part of this audit.

Coverage note: this read-only live comparison does not replace a full inventory of every writer/trigger/service-role path or deployed runtime test.


## Tenth-round focused settlement remediation draft (2026-11-02)

Added `supabase/drafts/settle-encounter-session-parent-lock-live-reconciliation.sql` as a focused, draft-only replacement for the live settlement RPC.

- Keeps the exact live identity signature: `settle_encounter_session(uuid, integer, text, jsonb, jsonb)`.
- Preserves SECURITY DEFINER and `search_path TO ''`.
- Adds a first lock on `chat_sessions` with `chat_mode='encounter'` and `deleted_at IS NULL`; failure raises before lifecycle lookup and before already-settled idempotent return.
- Then locks lifecycle, retains pending pre-expiry charge and evidence-count guards, and updates relationship state only after the parent gate.
- Explicitly revokes EXECUTE from PUBLIC/anon/authenticated and grants service_role, matching the live observed execution audience; postgres remains function owner.
- Includes required local rollback fixture scenarios: delete-first, settlement-first, already-settled-but-deleted, and wrong chat mode.

No SQL was executed against local or hosted databases in this round. No concurrency behavior is claimed as tested. The new file is a proposal only and is not a migration. Before promotion, validate owner/ACL after CREATE OR REPLACE and execute the concurrency fixtures in a disposable local database. The existing broad draft `encounter-session-delete-lifecycle-guards.sql` remains a separate proposal and should be reconciled to avoid duplicate/conflicting function definitions when preparing a migration.


## 第十一輪（2026-11-02）：Settlement 草案去重與本機測試環境確認

### 草案整併
- `encounter-session-delete-lifecycle-guards.sql` 原本也定義 `public.settle_encounter_session(uuid, integer, text, jsonb, jsonb)`，與專項檔案重複。
- 已移除廣義 lifecycle 草案中的第二份函式定義，改為明確指向唯一 canonical 草案：`settle-encounter-session-parent-lock-live-reconciliation.sql`。
- 唯一 settlement 定義保留 parent-first `chat_sessions` lock、`chat_mode='encounter'`、`deleted_at IS NULL`，且在 lifecycle lock 與 settled idempotent return 之前完成 gate；保留 live observed EXECUTE audience（postgres/service_role only）。
- 這是 draft 去重，尚未將任何 SQL 移入 migration，也未執行 SQL。

### 本機測試能力
- 目前執行環境未找到 `supabase` CLI、`docker` 或 `psql` 可執行檔；因此不能聲稱已建立 disposable local DB 或執行交易競態測試。
- 不改用 hosted test DB 代替本機測試；不套用 migration、不修改遠端資料、不部署、不建立 chat deletion Cron。

### 下一個驗收門檻
1. 準備可重現的 disposable PostgreSQL/Supabase local stack（含必要 migrations/extensions），再執行 rollback-safe fixtures。
2. 驗證 delete-first、settlement-first、already-settled-but-deleted、wrong chat_mode 四種情境。
3. 再確認 broad lifecycle draft 其他函式的實際 trigger attachment、ACL 與呼叫路徑，避免只驗證函式本體。
4. 所有交易測試通過後，才整理成單一 migration 並送 PR review。


## 第十二輪（2026-11-02）：Trigger attachment / ACL 只讀驗收查詢

- 新增 `supabase/drafts/encounter-lifecycle-trigger-attachment-audit.sql`，僅包含 PostgreSQL catalog SELECT，沒有 DDL/DML。
- 查詢會列出 lifecycle、Encounter turns、evaluation jobs、Story relationship tables 的非內建 triggers、啟用狀態、trigger definition、實際綁定函式及函式安全設定。
- 另外檢查 `validate_affinity_session_link()` 與 `validate_encounter_evaluation_job_link()` 是否真的有 trigger attachment，避免只建立/替換函式卻沒有掛載而形成假防護。
- 第三段列出 pause/resume、settlement 與 validator 的 owner、SECURITY DEFINER、search_path 設定及完整 EXECUTE ACL（含 PUBLIC）。
- 這是待執行的只讀驗收腳本；目前環境沒有 Supabase CLI、Docker、psql，因此尚未執行，也沒有任何 live catalog 結果。不得將其描述為 trigger/ACL 已驗收。

### 下一步
1. 在 disposable local DB 套用完整 migration replay 後執行此 catalog audit。
2. 將實際 trigger attachment 與 ACL 結果逐一對照廣義 lifecycle draft 及專項 settlement draft。
3. 再執行四項交易競態測試；全部通過後才考慮整理正式 migration。
