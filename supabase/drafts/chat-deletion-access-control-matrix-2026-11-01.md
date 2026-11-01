# POYOZZ chat deletion access-control matrix — 2026-11-01

Scope: read-only inspection of test project `ouyewoagbmtqehbofrje`. This is an implementation matrix, not an executable migration. No schema or data was changed.

## Confirmed gaps

| Surface | Current observed behavior | Required 30-day lifecycle behavior |
|---|---|---|
| `chat_sessions` SELECT | Owner policy checks owner/account active, but not `deleted_at IS NULL` | Deleted sessions excluded from ordinary client reads immediately |
| `chat_sessions` UPDATE | Owner policy checks owner/account active, but not deleted marker | No client update after soft delete; lifecycle RPC is the only state transition |
| `chat_messages` SELECT | Owner via parent session, but no deleted marker | No message content visible after session soft delete |
| `chat_messages` UPDATE | Owner via parent session, but no deleted marker | No message edits after delete |
| `chat_message_versions` SELECT | Parent ownership check but no deleted marker | No versions visible after delete |
| `chat_groups` SELECT/UPDATE | Owner-only; group has no `deleted_at` | Add group lifecycle marker and hide/freeze immediately |
| `chat_groups` DELETE | Authenticated owner has direct DELETE policy | Revoke direct client DELETE; only atomic lifecycle RPC can soft-delete |
| Group children (members/messages/turns/scenes/diary/photos) | Several policies check owner only; some check `archived_at` | All child reads/writes must check group `deleted_at IS NULL` |
| `chat_memory_photos` UPDATE | Owner-only update policy | Enforce parent session/group active state and lifecycle-controlled transitions |
| Group photo policies | Parent group check uses `archived_at IS NULL` | Check explicit `deleted_at IS NULL`; archived is not deleted |
| Storage memory photos | Broad owner-folder SELECT/INSERT/DELETE policies coexist with narrower chat-aware policies | Remove broad permissive policies after confirming path formats and replacement semantics; narrow policies must be sole authorization path |
| Photo expiry trigger | INSERT trigger resets status/deleted_at/attempts | Must reject insertion for deleted parent and never reactivate a deleting/deleted photo |
| Message version trigger | Saves OLD content before message content updates | Purge must bypass version creation through a tightly scoped worker-only path; normal updates continue versioning |
| Assistant message guards | Check charge, but parent lifecycle not consistently locked/gated | Parent-first lock and active-state gate for all new assistant content |
| Group append RPC | Parent row lock; checks archived only | Parent row lock; recheck deleted marker under lock |
| Single reserve RPC | Checks session deleted marker without parent row lock | Lock session first, recheck deleted marker, then charge/wallet |
| Settle/refund | Charge lock without parent lifecycle lock | Permit only settlement/refund of pre-delete reserved turns; no new generation/content |

## Referential and financial retention

Observed FKs that can remove or block retained chat/billing evidence:

- `chat_turn_charges.session_id → chat_sessions.id ON DELETE CASCADE`
- `chat_turn_charges.user_message_id → chat_messages.id ON DELETE RESTRICT`
- `chat_turn_charges.assistant_message_id → chat_messages.id ON DELETE SET NULL`
- `chat_turn_events.turn_id → chat_turn_charges.turn_id ON DELETE CASCADE`
- `chat_group_turn_charges.group_id → chat_groups.id ON DELETE CASCADE`
- `chat_group_turn_charges.group_turn_id → chat_group_turns.id ON DELETE CASCADE`
- `chat_group_messages.scene_id/group_id → chat_group_scenes ON DELETE RESTRICT/CASCADE`
- `ai_generation_records` references session, user/assistant messages with NO ACTION and has non-null `original_content`.
- `chat_message_versions.message_id` is NO ACTION.

Design consequence: the 30-day chat purge must not erase the wallet ledger or turn charge/event audit trail. Before hard purge, migrate billing/audit evidence to durable independent IDs/snapshots (or another reviewed retention model), detach chat FKs, and apply an explicit AI generation content-retention policy. Never solve FK errors by deleting wallet transactions.

## Storage policy OR behavior

Postgres permissive policies combine with OR. The three broad policies named:
- `Users can read own PersonaX memory photos`
- `Users can upload own PersonaX memory photos`
- `Users can delete own PersonaX memory photos`

only validate the first path segment as the current user's folder. They can therefore bypass chat-aware policies that check the parent session/group. Corrective work must inventory every client path and any upsert behavior, then remove/replace the broad policies atomically with tested narrow policies. Keep character illustration/video policies and buckets out of chat cleanup.

## Migration-chain replay blockers

The GitHub `main` migration directory contains duplicate version prefixes:
- `20261015151500`: freeze_group_access_pending_deletion; optimize_rls_auth_initplan_policies
- `20261020120000`: restrict_test_diamond_grant_rpc; unified_memory_album
- `20261023120000`: exclude_deleted_group_messages_from_turn_counts; protect_whisper_reply_direct_select
- `20261024170000`: enforce_nsfw_age_gate_for_character_reads; fix_owner_nsfw_character_read
- `20261031120000`: author_encounter_schedule_descriptions; character_illustration_display_names; encounter_turn_evidence_writer
- Five legacy SQL files have only an 8-digit date prefix and no unique 14-digit timestamp.

The repository migration chain cannot be assumed replayable until these duplicate/legacy versions are resolved in a separately reviewed way. Do not rename already-applied migration history or hand-edit the remote schema_migrations table. First test replay in a disposable local/project environment and document the exact Supabase CLI behavior.

## Implementation order

1. Freeze the schema baseline and migration replay plan.
2. Introduce group deleted marker and durable deletion/purge queue only after baseline approval.
3. Decouple billing and generation audit records from chat FK cascades.
4. Replace single/group delete RPCs with atomic soft-delete + queue enqueue.
5. Apply parent-first lock and lifecycle checks to every write path.
6. Close RLS and Storage policy bypasses; test all authenticated/anon paths.
7. Add worker-only purge path after 30 days with idempotency, retry/backoff and dead-letter.
8. Test race conditions, rollback, storage failure, signed URL behavior, and exclusion of character assets.
