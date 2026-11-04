# Account deletion — archive/prepare RPC data-loss gate audit — Round 45 — 2026-11-02

PR #200: Draft / unmerged
Environment: read-only inspection of live test-project function definitions, table columns and FK rules.
No RPC invocation, DDL/DML, Auth/Storage mutation, deployment or Cron change.

## Executive finding

The current account-deletion RPC chain does not preserve character-owned durable content before the worker deletes the Auth user.

The live `archive_account_deletion_data(p_user_id)` currently snapshots only:
- `ai_generation_records`
- `wallet_transactions`

It verifies those two source sets against archive payloads, then marks the batch archived.

The live `prepare_account_deletion(p_user_id)`:
- backfills/verifies `chat_turn_charges` and `chat_turn_events` archive payloads;
- marks the batch `deleting`;
- deletes `ai_generation_records`;
- deletes version history for the account's own chat messages;
- sets `chat_message_versions.edited_by = NULL` for versions belonging to other users' messages;
- deletes `chat_turn_charges` and `wallet_transactions`;
- deletes `conversations` (whose owned chat data is removed through its declared relationships).

It does NOT first preserve or detach:
- `characters`
- `character_private_info`
- `character_stories`
- `character_schedules`
- `character_schedule_descriptions`
- `character_illustrations`
- `characters.avatar_video_path` references

Then the worker calls Auth Admin `deleteUser(userId)`. The live FK `characters.author_id -> profiles.id ON DELETE CASCADE` and related author FKs mean character rows and related records can be deleted by the subsequent Auth/profile cascade. Illustration metadata also has profile CASCADE and character CASCADE. This violates the confirmed account-deletion retention requirement.

## Table-specific data treatment observed

| Data | Current prepare behavior | Required before enabling account deletion |
|---|---|---|
| Characters and content | Not archived/detached | Preserve every row and all fields; archive from discovery; detach active owner without deleting historical attribution. |
| Character private info | Not archived/detached; profile and character FKs cascade | Preserve settings; deny former account and public access. |
| Character stories | Not archived/detached; character FK cascade | Preserve; force private/archived and block new story sessions. |
| Character schedules | Not archived/detached; character FK cascade | Preserve settings; make inaccessible to former account; no new encounter schedule eligibility. |
| Schedule descriptions | Not archived/detached; character FK cascade | Preserve settings with same access restrictions. |
| Character illustrations | Not archived/detached; profile + character CASCADE | Preserve metadata and private Storage objects. |
| Avatar video path | Stored on characters row | Preserve path and underlying private bucket object. |
| AI generation records | Full payload archived, then source rows deleted | Current behavior preserves archive payload, but its FK dependencies to chat messages/sessions must be considered when retaining/removing source. |
| Wallet transactions | Full payload archived, then source rows deleted | Current archive keeps payload, but user previously required charge/refund audit evidence; confirm archive access/retention and no loss of ledger integrity. |
| Chat turn charges/events | Full payload archived, then source rows deleted | Existing behavior is intended to preserve charge evidence; keep independent from chat content purge. |
| Message versions | Own chat versions deleted; editor attribution nulled on other users' messages | Preserve other players' message history; ensure NULL editor is acceptable and no other ownership evidence is lost. |
| Conversations | Deleted before Auth deletion | User-owned chat state is separate from durable character content; existing other-player sessions must not be deleted by character owner account deletion. |

## Important FK implications

- `characters.author_id` and `character_illustrations.author_id` both reference profiles with ON DELETE CASCADE.
- `character_private_info.author_id` references profiles with ON DELETE CASCADE; it also references characters with ON DELETE CASCADE.
- `character_stories`, `character_schedules`, and `character_schedule_descriptions` reference characters with ON DELETE CASCADE.
- `ai_generation_records` references profiles, sessions and messages with NO ACTION; prepare explicitly deletes generation rows before deleting the account's conversations.
- `chat_message_versions.edited_by` references profiles with NO ACTION; prepare explicitly nulls editor references on other users' message versions.
- `wallet_transactions.user_id` references profiles with ON DELETE CASCADE, but prepare explicitly snapshots then deletes them before Auth deletion.

## Additional safety observations

1. The archive batch currently does not have character-related source rows, so its payload cannot be used to reconstruct missing character data if a later cascade occurs.
2. Archive payloads alone are not enough for the product requirement: existing player chats and scene/media loaders still need stable live character records and exact linked media metadata.
3. Account deletion must not reuse manual character deletion semantics. Manual character deletion may hard-delete a never-published, never-used character; account deletion must preserve every character regardless of publication or use history.
4. Do not change wallet retention behavior as part of character preservation without a separate audit; financial ledger retention and user account privacy need their own policy.
5. Existing session continuation must remain available for every player who already started a chat, while all new single/group/encounter/story sessions for account-archived characters are rejected.

## Required fix order

1. Design and implement durable creator attribution independent of Auth/profile.
2. Add explicit active-owner/account-archive state; do not overload `deleted_at` or historical attribution as authorization.
3. Preserve characters and all character-owned settings/media metadata before Auth deletion, and detach current owner FK without cascading the character.
4. Rework all dependent RLS policies, triggers, functions, views, frontend author queries and Storage access.
5. Prove exact session-bound media reads for existing players while keeping private buckets private.
6. Reconcile worker ordering and crash/retry behavior so character preservation is transactional and complete before Auth delete.
7. Use disposable local test fixtures to prove all rows and objects survive; prove former account cannot manage them; prove existing players continue; prove no new session path works.
8. Only after those tests pass, review worker and migration enablement separately.

## Release gate

- Account-deletion worker must remain disabled/un-deployed.
- PR #200 remains Draft/unmerged.
- Test grace period remains 5 minutes; production target remains 30 days.
- This round only read function definitions, catalog metadata and FK rules. No RPC was invoked and no hosted data/schema/auth/storage was modified.
