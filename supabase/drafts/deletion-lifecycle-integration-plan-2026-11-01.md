# POYOZZ deletion lifecycle integration plan — 2026-11-01

Status: cross-feature dependency note. Chat deletion remains the active implementation priority. Character deletion and account deletion are subsequent phases; this document does not change database state.

## Product-level sequence

1. Complete and verify chat deletion for both single and group chats.
2. Complete character deletion without destroying player-owned historical chats or financial evidence.
3. Complete account deletion, coordinating pending chat and character cleanup jobs and preserving only approved audit/archive records.

All phases use the existing Supabase test project. Do not create paid branches/projects, reset the test DB, edit remote migration history, or touch production without explicit authorization.

## Phase 1 — chat deletion (current PR #200)

- One lifecycle contract for single sessions and groups; group has one player and multiple AI characters.
- User-facing deletion immediately hides and freezes the conversation.
- Keep chat content for 30 days, then purge chat text, versions, chat-only memory images and raw generation content according to the approved retention matrix.
- Preserve wallet transactions, charge/refund evidence, idempotency metadata and required audit records.
- Character avatars, illustrations and videos are not chat-memory assets and must never enter the chat cleanup allowlist.
- The durable chat deletion job must not have a cascading FK to chat_sessions, chat_groups, profiles, or auth.users; retain immutable owner/resource IDs so later account cleanup cannot erase the queue.
- Account deletion must coordinate with any queued chat purge and may not silently bypass the 30-day chat retention contract or erase the durable queue.

## Phase 2 — character deletion (existing soft-delete foundation)

### Existing observed behavior

- soft_delete_character(uuid) is SECURITY DEFINER, owner-checked, locks the character row, and idempotently sets visibility=private, review_status=draft, deleted_at, and deletion_reason=author_deleted.
- It makes character stories private and updates snapshots in chat_sessions, chat_group_members, and chat_group_messages.
- Existing player chat history is retained; deleted characters must not be offered for new chats.
- Restore is blocked by prevent_character_soft_delete_restore.
- character_illustrations stores separate illustration asset paths; character avatar video paths are stored separately and use the private character-avatar-videos bucket.

### Additional account-deletion gap found during chat queue integration audit (2026-11-01)

- prepare_account_deletion(uuid) archives single-chat chat_turn_charges and chat_turn_events, then deletes ai_generation_records, chat_message_versions, chat_turn_charges, wallet_transactions, and legacy conversations.
- archive_account_deletion_data(uuid) archives AI generation records and wallet transactions; the prepare step adds single-chat charge/event archives. Neither function currently archives chat_group_turn_charges.
- The prepare function does not explicitly delete chat_sessions, chat_groups, chat_messages, chat_group_messages, or chat_group_turns.
- Current FK inventory shows chat_sessions.user_id and chat_groups.owner_id have no FK to profiles or auth.users; deleting Auth/profile therefore does not automatically remove these chat parent rows. This can leave orphaned chat content after account deletion unless the account workflow explicitly handles it.
- chat_group_turn_charges is FK-cascaded by chat_groups and chat_group_turns, but is not included in the current account archive. If a later account cleanup removes groups/turns, group billing evidence could be lost.
- The new chat_deletion_jobs and chat_storage_deletion_jobs are not referenced by the current account deletion functions; their owner/resource columns have no FK to account/chat parents, so pending cleanup work survives current account/profile parent deletion paths. Preserve this invariant in future changes.
- Follow-up FK inspection confirms group messages, members, scenes, diary, group photos, turns and group charges cascade from group/turn parents; single messages, single charges, encounter lifecycle/turns and story relationship rows cascade from session parents. This makes archive-before-parent-delete ordering mandatory.

This is recorded for Phase 3; do not silently expand PR #200 into account deletion. The account phase must first add group-charge archive coverage, explicit chat content cleanup, and a verified rule for pending 30-day chat jobs.

### Remaining implementation/verification

- Confirm all public discovery, encounter schedule, profile/story, search, and direct RPC paths reject deleted characters.
- Confirm the existing chat snapshot remains readable to the player without re-exposing the deleted character publicly.
- Inventory every character asset path (main avatar, illustration gallery, avatar video) and its storage bucket/policy.
- Add owner-verified durable cleanup for character assets with retry/dead-letter behavior; never use the chat-memory bucket or chat cleanup worker for these assets.
- Decide and test the historical-chat rendering policy before deleting assets referenced by snapshots (e.g. preserve a safe display snapshot/thumbnail or intentionally remove asset access without leaking private files).
- Ensure character deletion does not delete player chats, messages, chat charges, wallet transactions, or group speaker snapshots.

## Phase 3 — account deletion (existing request/archive foundation)

### Existing observed behavior in current test project

- request_account_deletion(), cancel_account_deletion(), get_account_deletion_status(), get_account_deletion_work_items(), archive_account_deletion_data(), prepare_account_deletion(), finalize_account_deletion(), and failure recording RPCs exist.
- Account deletion requests use account_deletion_settings.grace_period. Current test-project setting is 5 minutes; this is a test configuration and must not be copied into production. The repository includes a migration restoring a 30-day default for future requests, but the live request RPC reads the settings row.
- prepare_account_deletion verifies archived payloads for AI generation records, wallet transactions, single-chat turn charges, and single-chat turn events before deleting source rows. It does not currently archive group turn charges.
- prepare_account_deletion deletes AI generation records, relevant message versions, single-chat charge rows, wallet transactions, and legacy conversations. It does not explicitly delete chat_sessions, chat_groups, chat_messages, chat_group_messages, or chat_group_turns.
- finalize_account_deletion only marks a batch completed after the Auth user is absent.
- Archive batch/item tables exist and currently contain no batches/items in the test project.
- Current project has only one active pg_cron job, for encounter-evaluation dispatch. No account-deletion worker Edge Function or account-deletion cron invocation was found in the project inventory during this audit.
- Storage object ownership is not enforced by an FK to auth.users. Character illustration paths use {author_id}/{character_id}/{asset_uuid}.{ext}; avatar-video objects use the author folder; chat-memory objects use {owner_id}/single|group/{chat_id}/{asset_uuid}.{ext}. Cleanup must validate each bucket's own path contract and ownership, not issue a broad owner-prefix delete.
- Character illustrations and avatar videos are character assets, not chat assets. Account deletion must coordinate their cleanup with character ownership and historical-chat display rules, while chat purge remains restricted to personax-memory-photos.

### Remaining implementation/verification

- Trace the full worker path from due request → archive → prepare → chat/character asset queues → profile cleanup → Auth Admin deletion → finalize; identify exactly which step invokes each RPC.
- Implement/verify a scheduled service-role worker with leases, bounded retries, idempotency and dead-letter handling; do not rely on an RPC merely existing.
- Add archive coverage for chat_group_turn_charges, verify exact payload/count parity, and only then allow group/turn cleanup.
- Verify cancel-vs-worker race and account lock/freeze behavior across all write paths.
- Coordinate account deletion with pending chat deletion jobs and character asset cleanup jobs; preserve job rows independently of the account/profile being deleted and explicitly decide whether 30-day chat retention remains in force for account deletion.
- Define and test archive retention/access/deletion policy for financial and security evidence; do not invent legal retention periods.
- Remove account-owned Storage objects across approved buckets without touching other users' assets.
- Verify Auth user deletion, profile cascades, and retry safety end-to-end using a dedicated disposable test account only.

## Shared invariants

- No direct client DELETE may bypass a lifecycle RPC.
- Parent-first locking and explicit lifecycle gates prevent writes racing with deletion.
- Queues store immutable resource/owner references and survive parent/profile/Auth deletion.
- Each queue has a strict bucket allowlist and validates owner/resource path before deletion.
- Billing ledger and required audit evidence are not deleted as a side effect of chat or character deletion.
- Account deletion is the only phase that removes the account identity; it must archive and verify required evidence before irreversible cleanup.
- Every implementation, test, repair, blocker and policy decision is recorded in Notion P23-03 and the relevant PR.


## 2026-11-01｜帳號待刪除鎖定與前端流程查核

- 前端 `index.html` 已串接 `get_account_deletion_status()`、`request_account_deletion()`、`cancel_account_deletion()`：申請前要求輸入 DELETE 並再次確認；申請後顯示後端期限及取消入口；登入時重新向 DB 查狀態，待刪除帳號只讀取既有錢包，不初始化／補發餘額。這證明申請與取消 UI/RPC 有串接，但不代表實際到期 worker 存在。
- 前端在待刪除期間設有大部分互動攔截；後端 `account_is_active()` 以是否存在 account_deletion_requests 作為狀態依據。資料庫 ACL 確認 request/cancel/status 僅 authenticated 可執行，archive/prepare/finalize/work-items/failure RPC 僅 service_role 可執行，anon 無執行權。
- 查核 `account_is_active()` 的 public/private 函式呼叫，目前只出現在少數 RPC（群聊 append、wallet ensure、profile save、角色刪除、相簿照片刪除、角色快照同步等）；並非所有 Edge Function/service-role 寫入都會自動受 RLS 保護。帳號 worker 與所有 service-role 路徑必須自行驗證刪除狀態及 owner。
- 公開 schema RLS policy 查核：多數角色、聊天室、群聊、訊息、profile 寫入政策已套用 account_is_active()；但 Storage 的 `Character video owner upload` 與 `Character video owner update` policy 目前只有 bucket + owner folder 條件，未檢查 account_is_active()。待刪除帳號可能仍能直接透過 Storage API 上傳／更新角色影片，需補後端政策 gate 並做拒絕測試。
- 本輪未修改任何 RLS policy、未呼叫刪除 RPC、未建立帳號刪除 worker／Cron。新增待辦：修補角色影片 Storage INSERT/UPDATE pending-deletion gate；並逐一驗證 Edge Function service-role 寫入路徑不受前端 UI gate 取代。
