# Chat deletion aggregate-count and trigger audit — 2026-11-01

Repository: elmjp1990-ux/my-ai-roleplay  
Branch: security/chat-deletion-lifecycle-reconciliation  
Test Supabase project: ouyewoagbmtqehbofrje  
Scope: read-only catalog/function/policy review. No DDL or data changes.

## Confirmed positive controls

- Live definition of public.append_chat_group_mock_turn checks owner, archived_at IS NULL, and deleted_at IS NULL while locking the chat_groups parent row before it can reserve a group turn or charge the wallet.
- Restrictive active-lifecycle policies exist on chat_groups, chat_group_messages, chat_group_members, chat_group_turns, chat_group_diary, and chat_group_memory_photos. They check the parent chat_groups.deleted_at IS NULL.
- Although some permissive owner SELECT/UPDATE policies do not themselves repeat deleted_at, the corresponding restrictive lifecycle policies also apply to authenticated access and block access when the parent group is deleted.
- chat_sessions and chat_messages have corresponding restrictive parent lifecycle guards. The existing message insert policy also checks the parent session is not deleted.

## Finding A — character turn-count functions include deleted group conversations

Two live SECURITY DEFINER functions are executable by anon and authenticated:
- public.get_public_character_turn_count(uuid)
- public.get_character_turn_counts(uuid[])

Both functions filter deleted single sessions and deleted individual group messages, but their group-count CTE/subquery reads public.chat_group_messages without joining public.chat_groups and checking chat_groups.deleted_at IS NULL.

Because chat deletion intentionally retains group messages during the 30-day backend grace period while the parent group is immediately hidden, these functions can continue counting character messages from a deleted group during that grace period. This is a stale aggregate/metadata issue; this audit did not find evidence that it exposes message content or restores deleted chat access.

Suggested function correction (not applied):
- Join chat_group_messages gm to chat_groups g on g.id = gm.group_id.
- Add g.deleted_at IS NULL to the group-count predicates in both functions.
- Preserve gm.deleted_at IS NULL and existing character visibility / NSFW / ownership predicates.
- Add regression coverage proving active group turns still count and soft-deleted group turns no longer count, for both anonymous public count and author count paths.

No function was altered in the database or repository during this audit because the supported migration creation/reconciliation workflow remains blocked by the project's migration-history drift and the current environment has no local Supabase CLI/Docker.

## Finding B — two trigger validators lack an explicit deleted-parent predicate

Read live definitions:
- public.validate_affinity_session_link()
- public.validate_encounter_evaluation_job_link()

Both validate parent session ownership/character/chat mode but do not explicitly require chat_sessions.deleted_at IS NULL.

Privilege check for their target tables found INSERT/UPDATE granted only to service_role; anon and authenticated have no direct INSERT/UPDATE privileges on:
- encounter_session_evaluation_jobs
- encounter_session_lifecycle
- encounter_session_turns
- encounter_turn_interaction_receipts
- story_relationship_batches
- story_relationship_states

Therefore this is currently a defense-in-depth hardening item for trusted backend writes, not a demonstrated client-side bypass. Review the service-role creation/enqueue call graph and decide whether the trigger validators should also reject deleted parent sessions. Do not block necessary refund/settlement/audit completion for already-reserved charges.

## Decision / next steps

1. Treat Finding A as a confirmed correctness/privacy-metadata defect to fix in the next reviewed migration.
2. Review Finding B alongside service-role call graph; explicitly distinguish new lifecycle creation from permitted financial reconciliation.
3. Add regression tests after a migration is safely created and applied to the test database.
4. Keep PR #200 Draft/unmerged; do not enable chat deletion cron.
5. Keep PR #201 account deletion paused.
6. Do not modify hosted migration history, use db reset/db push/migration repair, or apply ad hoc DDL to work around the current migration drift.

This is a read-only audit record, not a claim that either finding has been fixed.
