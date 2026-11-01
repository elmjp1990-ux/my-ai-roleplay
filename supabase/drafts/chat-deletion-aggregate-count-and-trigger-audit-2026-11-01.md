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

## Finding A — historical group-turn aggregate interpretation corrected (not a defect)

Two live SECURITY DEFINER functions are executable by anon and authenticated:
- public.get_public_character_turn_count(uuid)
- public.get_character_turn_counts(uuid[])

The earlier audit noticed that their group-count paths read character messages without joining chat_groups.deleted_at. It incorrectly labeled this as a defect because deleted-group turns remained counted during the 30-day grace period. That conclusion is withdrawn: the product requirement is that every successfully completed AI character reply in a group contributes to that character's cumulative total, and deleting the group must not erase that historical contribution.

The correct implementation must switch the source of the contribution, not remove it:
- Active single/group parents contribute from their live valid assistant/character message rows.
- A deleted single/group parent contributes from one immutable per-character aggregate snapshot captured in the delete transaction.
- After day-30 transcript purge, the same archived aggregate remains in both owner-visible and public count paths, subject to the existing character visibility, ownership, NSFW and deleted-character gates.
- A deleted parent must not be counted from both live rows and its archive snapshot.

The historical migration file 20261023095003_exclude_deleted_chat_from_character_turn_counts.sql is retained as migration provenance and must not be rewritten as historical SQL. The cumulative snapshot proposal supersedes its counting behavior when safely implemented. Its test requirements must prove that deleting a group does not reduce any participating character's total, that counts remain after purge, and that retries never duplicate the archived contribution.

No database function or hosted schema was changed during this audit. The cumulative snapshot proposal remains draft-only pending migration-baseline/replay resolution and transactional fixture tests.

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


## Follow-up — service-role lifecycle call graph narrows Finding B

A second read-only pass checked trigger attachment points and the service-role functions that create or enqueue the affected rows.

- The two trigger validators are attached to encounter lifecycle/evaluation and story/encounter relationship tables.
- Those tables' direct INSERT/UPDATE privileges are service_role-only; anon/authenticated have no direct write grants.
- enqueue_due_encounter_evaluations filters parent sessions with deleted_at IS NULL before inserting evaluation jobs.
- claim_encounter_evaluation_jobs also filters deleted sessions before claiming.
- record_encounter_session_turn_evidence and record_encounter_turn_interaction explicitly lock/check the parent session with deleted_at IS NULL.
- create_encounter_session_with_lifecycle creates a brand-new chat_sessions parent and then its lifecycle row in the same transaction; it is not reusing a deleted parent.
- create_story_session_with_relationship creates a new story parent. Its story relationship origin trigger validates the source encounter session is not deleted when origin_mode is encounter_snapshot.

Therefore Finding B is narrowed: the trigger validators themselves lack a repeated deleted_at predicate, but the reviewed service-role call paths either create a fresh parent or apply an active-parent guard. No client-side bypass or current service-role bypass was demonstrated in this targeted pass. Keep an explicit deleted-parent guard on validators as optional defense-in-depth hardening, but do not label it a confirmed exploitable defect. Preserve the existing ability to settle/refund already-reserved charges and write necessary financial audit records.

Finding A (public/author character turn-count aggregates missing the deleted group parent join) remains the confirmed functional issue requiring a reviewed migration.
