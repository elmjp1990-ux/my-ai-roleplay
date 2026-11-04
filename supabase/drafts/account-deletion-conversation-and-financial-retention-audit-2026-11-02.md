# Account deletion — legacy conversations vs chat_sessions and financial evidence — Round 48 — 2026-11-02

Status: read-only audit and design note. No schema/code mutation this round.
PR #200 remains Draft/unmerged. The fixed worker 503 guard remains mandatory.

## 1. The two conversation models are not interchangeable

### Legacy `conversations` / `messages`
Verified live columns/FKs:
- `conversations(id, user_id, story_id, title, status, created_at)`
- `conversations.user_id -> profiles.id ON DELETE CASCADE`
- `conversations.story_id -> character_stories.id ON DELETE CASCADE`
- `messages.conversation_id -> conversations.id ON DELETE CASCADE`

The current `prepare_account_deletion()` explicitly deletes `conversations WHERE user_id = p_user_id`; that cascades to its `messages`. This is the deleting account's own legacy conversation history. It is not the modern player-to-character chat model. Preserve/erase policy for this account-owned legacy history must be treated separately from the requirement that other players' existing chats with the account's characters continue.

### Modern `chat_sessions` / `chat_messages`
Verified live columns/FKs:
- `chat_sessions(id, user_id, character_id, character_name, status, character_snapshot, session_data, deleted_at, chat_mode)`
- `chat_messages.session_id -> chat_sessions.id ON DELETE CASCADE`
- `chat_sessions.character_id -> characters.id ON DELETE SET NULL`
- No profile FK was returned for `chat_sessions.user_id` in the live FK catalog query.
- Story relationship and encounter lifecycle records reference `chat_sessions` and cascade if the session itself is deleted.
- Chat-turn charges reference `chat_sessions` with CASCADE; user message deletion is RESTRICT until charges are removed.

The existing player’s chat is keyed to the player's own `chat_sessions.user_id`, not to the character author's profile. Therefore deleting a character author must not delete other players' `chat_sessions`, messages, encounter/story lifecycle, relationship states, or billing history. Keeping the original character row and its child data in place is the least destructive approach.

Important: `chat_sessions.user_id` lacking a profile FK means the DB may retain an orphaned UUID for a deleted player account. That does not by itself prove the deleted player can still authenticate or read the session. The app's account-deletion policy for the deleting player's own sessions is a separate decision and needs explicit authorization/access semantics; do not infer it from author-character retention.

## 2. Character deletion vs account deletion impact

- Manual character soft-delete: keep all players' existing sessions and allow continuation; block new sessions.
- Author account deletion: same existing-player continuation requirement, but additionally preserve the character and child rows for historical attribution and media access.
- Do not run a bulk cleanup by `character_id` or `author_id` that touches other players' sessions.
- Character references set NULL only if the character row is actually deleted; retaining character rows avoids this loss.

## 3. Wallet data — what current prepare does

Verified columns:
- `wallet_accounts(user_id, diamonds, silver_coins, updated_at)`
- `wallet_transactions(id, user_id, currency_type, amount, biz_type, reference_id, created_at)`
- `chat_turn_charges(turn_id, user_id, session_id, user_message_id, expected_assistant_message_id, assistant_message_id, cost, silver_reserved, diamonds_reserved, status, failure_code, created_at, reserved_at, settled_at, refunded_at, updated_at)`
- `chat_turn_events(event_id, turn_id, user_id, event_type, stage, error_code, retryable, attempt, duration_ms, created_at)`

Current prepare archives wallet_transactions, chat_turn_charges and chat_turn_events into `account_deletion_archive_items.payload`, verifies exact row counts/payload equality, then deletes those source rows. Wallet account itself is profile-cascaded. This is an irreversible move from operational tables to a JSONB archive, not preservation in the live ledger.

Required controls before acceptance:
- Keep archive rows inaccessible to ordinary users; access only via audited admin/legal workflow.
- Verify archive retention policy and whether financial/tax/dispute evidence requires a longer fixed retention than general account data.
- Ensure archive table/batch has no FK back to profiles and is not deleted by any later cleanup.
- Preserve source IDs, amounts, currency, transaction type, references, timestamps, charge statuses, reservations, settlement/refund timestamps and event sequence.
- Verify counts and exact payloads before deleting source rows (existing code does count/payload checks for the charge/event rows).
- Decide whether the user can obtain an account-close statement before Auth deletion; do not expose archive payloads through normal APIs.
- Do not keep wallet balance as spendable after account deletion; no refund/transfer behavior should be inferred without policy.

## 4. AI generation records — separate content-retention concern

Verified columns include `user_id`, `session_id`, user/assistant message IDs, `request_id`, `original_content`, `status`, `created_at`. FKs to profiles, sessions and messages are NO ACTION.

Current prepare archives full rows into JSONB and then deletes source rows to clear NO ACTION blockers. This preserves the payload in the archive table but removes the relational live record. Since `original_content` can contain generated text, this is content-bearing data, not merely operational telemetry.

Required controls:
- Confirm purpose and retention period for raw original_content; minimize retention if not required.
- Ensure archive access is tightly restricted and retention expiry is enforced.
- Avoid exposing archived generation content to the deleted user or other players.
- Preserve linkage identifiers in the archive payload for audit only; do not reconnect to player chat APIs.
- If product policy only needs operational metrics, consider archiving a minimized metadata projection and removing original_content after an explicitly approved retention period. Do not implement this without approval.

## 5. Key conclusions

- The explicit deletion of `conversations` in prepare affects the deleting account's legacy conversation rows and cascades to legacy `messages`; it does not target other players' modern `chat_sessions`.
- Do not conflate legacy `conversations` with modern `chat_sessions`.
- The user's core requirement is that other players' existing sessions with the deleted author's characters survive and remain usable. Those sessions must not be deleted or orphaned by character hard-delete; retain characters in place.
- Wallet and AI generation evidence is currently moved to restricted JSONB archive before source deletion. This is technically verified but retention/access policy remains a product/legal decision.
- Do not alter archive deletion semantics, balances, or legacy conversation retention until policy is confirmed. Worker remains disabled regardless.

## 6. Safety and next gates

Read-only catalog SELECTs only. No RPC invocation, DDL/DML, Auth/Storage mutation, deployment, or Cron.
Next engineering gates:
1. Recover/restore the missing foundational schema migrations to enable reliable local replay.
2. Inspect archive table RLS, grants, indexes, cleanup/retention jobs and every reader.
3. Inspect all legacy conversation UI/API call sites and establish whether this model is still used or merely legacy.
4. Implement durable creator attribution + owner detachment and account-archived gating as one reviewed migration series.
5. Local tests prove account deletion does not affect other players' chat_sessions/messages, encounter/story records, or ability to continue.
6. Worker 503 guard stays in place until all acceptance gates pass.
