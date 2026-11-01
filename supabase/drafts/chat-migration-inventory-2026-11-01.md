# POYOZZ migration inventory reconciliation — 2026-11-01

Read-only comparison. Test project: ouyewoagbmtqehbofrje. Repository ref: main at 0a951f290d6594a520afb4ab0dc3177a8ab16a24 (PR #199 merge commit).

## Summary

- Live Supabase history: 141 entries.
- Repository migration SQL files: 96.
- Shared migration names: 82.
- Shared names with different version prefixes: 67.
- Live-only names: 57.
- Repository-only names: 14.
- Duplicate live version values: none.
- Duplicate repository version prefixes: 20261015151500 (2), legacy (5), 20261020120000 (2), 20261023120000 (2), 20261024170000 (2), 20261031120000 (3).

These inventories are not a replay-equivalent migration chain. Do not apply, rename, or repair migration history from this list alone.

## Shared names with version mismatch

| Migration name | Live DB version | Repo file prefix |
|---|---:|---:|
| guard_pending_deletion_group_activity | 20261015150134 | 20261015150500 |
| freeze_group_access_pending_deletion | 20261015151600 | 20261015151500 |
| limit_deletion_archive_execution | 20261015151939 | 20261015163000 |
| freeze_pending_account_character_writes | 20261015153429 | 20261015170000 |
| harden_character_soft_delete_helper_rpc | 20261015153435 | 20261015153500 |
| restore_account_deletion_grace_period | 20261015154311 | 20261015180000 |
| restore_test_account_deletion_five_minute_grace_period | 20261015154925 | 20261015190000 |
| test_grant_diamonds_200_once | 20261018150329 | 20261018150500 |
| daily_checkin_silver_reward_cycle | 20261018151424 | 20261018162000 |
| unified_memory_album | 20261020045948 | 20261020120000 |
| memory_album_fk_indexes | 20261020050258 | 20261020123000 |
| memory_album_owner_updates | 20261020052245 | 20261020140000 |
| include_group_turns_in_character_counts | 20261021023530 | 20261021110000 |
| group_message_soft_delete | 20261021051029 | 20261021050000 |
| allow_group_message_soft_delete | 20261021062949 | 20261021060000 |
| add_character_phone_settings | 20261021093628 | 20261021100000 |
| create_group_sweet_diary_cloud_sync | 20261022055143 | 20261022130000 |
| index_group_sweet_diary_owner | 20261022055439 | 20261022130100 |
| backfill_deleted_character_chat_snapshots | 20261022180019 | 20261023013000 |
| secure_public_profiles_invoker_and_column_grants | 20261022180206 | 20261023014500 |
| save_my_profile_owner_checked_rpc | 20261022182628 | 20261023030000 |
| exclude_deleted_group_messages_from_turn_counts | 20261022185425 | 20261023120000 |
| group_chat_billing_per_character | 20261023035710 | 20261023012000 |
| restrict_public_default_privileges | 20261023092154 | 20261023040000 |
| protect_whisper_reply_direct_select | 20261023104741 | 20261023120000 |
| fix_safe_comment_rpc_whisper_ancestry | 20261023122555 | 20261023123000 |
| fix_whisper_reply_ancestry_authorization | 20261024061142 | 20261024090000 |
| character_nsfw_terms_and_age_gate | 20261024073819 | 20261024153000 |
| character_avatar_video_storage | 20261024073923 | 20261024154000 |
| fix_character_nsfw_rls_and_video_read | 20261024074821 | 20261024160000 |
| enforce_character_video_owner_path | 20261024074938 | 20261024161000 |
| move_adult_check_to_private_schema | 20261024075220 | 20261024162000 |
| enforce_nsfw_age_gate_for_character_reads | 20261024083626 | 20261024170000 |
| encounter_mode_core_schema | 20261028034854 | 20261028120000 |
| atomic_encounter_schedule_sync | 20261028055543 | 20261028143000 |
| trusted_encounter_interaction | 20261028072202 | 20261028160000 |
| safe_encounter_schedule_resolver | 20261028072315 | 20261028163000 |
| trusted_chat_mode_marker | 20261028075129 | 20261028170000 |
| enforce_trusted_chat_mode | 20261028080237 | 20261028173000 |
| encounter_session_access_check | 20261028080945 | 20261028180000 |
| idempotent_encounter_turn_interaction | 20261028103534 | 20261028190000 |
| prevent_duplicate_chat_message_charges | 20261028120032 | 20261028193000 |
| allow_all_eligible_public_encounter_schedules | 20261029011336 | 20261029120000 |
| validate_settled_encounter_interaction | 20261029224513 | 20261029210000 |
| affinity_system_foundation | 20261030213037 | 20261030120000 |
| encounter_turn_evidence_writer | 20261030215321 | 20261031120000 |
| encounter_scene_settlement | 20261030222510 | 20261031150000 |
| block_expired_encounter_turns | 20261030222553 | 20261031160000 |
| atomic_encounter_turn_reservation | 20261030224826 | 20261031170000 |
| allow_preexpiry_reserved_turn_completion | 20261030224911 | 20261031180000 |
| encounter_session_pause_resume | 20261030230919 | 20261031190000 |
| allow_preexpiry_encounter_retry | 20261031010419 | 20261031200000 |
| fix_encounter_retry_charge_lookup | 20261031010515 | 20261031210000 |
| restrict_encounter_retry_lifecycle_states | 20261031010719 | 20261031220000 |
| validate_story_batch_turn_sources | 20261031011247 | 20261031230000 |
| encounter_evaluation_dispatch_queue | 20261031011426 | 20261031240000 |
| bound_encounter_evaluation_retries | 20261031011509 | 20261031250000 |
| latest_settled_encounter_for_story | 20261031011944 | 20261031260000 |
| story_relationship_state_read_rpc | 20261031012300 | 20261031270000 |
| city_character_affinity_display | 20261031021650 | 20261031280000 |
| character_illustration_storage | 20261031033312 | 20261031100000 |
| fix_character_illustration_storage_policy_paths | 20261031033429 | 20261031103000 |
| character_illustration_display_names | 20261031055744 | 20261031120000 |
| author_encounter_schedule_descriptions | 20261031110122 | 20261031120000 |
| index_author_encounter_schedule_descriptions | 20261031110247 | 20261031120500 |
| character_illustration_cleanup_queue | 20261031131524 | 20261031211200 |
| fix_character_illustration_cleanup_path_check | 20261031131654 | 20261031212000 |

## Live DB-only migration entries

| Live DB version | Migration name |
|---:|---|
| 20261015083242 | make_account_deletion_archive_idempotent |
| 20261015083812 | harden_handle_new_user_trigger |
| 20261015084226 | allow_safe_recovery_before_deletion_processing |
| 20261015101628 | wallet_chat_turn_charging |
| 20261015130752 | chat_session_character_access |
| 20261015133300 | chat_turn_transaction_functions |
| 20261015134109 | chat_turn_ledger_idempotency |
| 20261015145637 | fix_reserve_chat_turn_conflict_target |
| 20261015150143 | add_missing_foreign_key_indexes |
| 20261016091809 | enforce_shared_group_scene_mode |
| 20261016093844 | validate_shared_group_scene_mode_constraint |
| 20261016100806 | allow_users_to_read_own_chat_turn_charges |
| 20261016102307 | grant_select_chat_turn_charges_authenticated |
| 20261016103434 | restrict_group_creation_to_shared_scene |
| 20261016103450 | harden_shared_scene_input_validation |
| 20261016104121 | require_public_approved_characters_for_groups |
| 20261016104703 | remove_character_review_approval_gate |
| 20261016112636 | restrict_private_character_reads |
| 20261016112651 | restrict_story_reads_to_public_characters |
| 20261016140139 | limit_chat_group_name_to_25_chars |
| 20261017010838 | preserve_group_history_on_character_delete |
| 20261017010841 | account_deletion_grace_period_config |
| 20261017010847 | account_deletion_worker |
| 20261017035145 | guard_group_mock_turn_during_deletion |
| 20261017040730 | guard_snapshot_sync_during_deletion |
| 20261017100648 | chat_turn_existing_retry_recovery_order |
| 20261018015010 | add_group_player_persona_and_world_character |
| 20261018015631 | guard_character_rpcs_during_deletion |
| 20261018083612 | character_comments_cloud_rls |
| 20261018083915 | secure_comment_likes_visibility |
| 20261018084032 | tighten_comment_mutation_permissions |
| 20261018084237 | restrict_comment_table_grants |
| 20261018090441 | secure_whisper_comment_redaction |
| 20261018090505 | fix_whisper_safe_reads_and_reply_policy |
| 20261018090614 | harden_whisper_redaction_deleted_content |
| 20261018090636 | fix_anonymous_whisper_redaction |
| 20261018103025 | profiles_insert_own_row_rls_fix |
| 20261018103253 | wallet_ledger_character_name_lookup |
| 20261018103858 | persist_persona_presets_on_profiles |
| 20261018115226 | add_profile_birthdate |
| 20261019123547 | create_private_personax_memory_photo_storage |
| 20261020054843 | fix_memory_album_mutation_permissions_and_group_storage_policy |
| 20261020061836 | secure_memory_photo_soft_delete_rpc |
| 20261022064137 | author_follow_tracking |
| 20261022065558 | character_nsfw_workplace_warning |
| 20261022072751 | grant_public_profile_columns_select |
| 20261022072918 | secure_public_profiles_and_restore_profile_reads |
| 20261022073159 | limit_public_profiles_view_to_select_only |
| 20261022094147 | delete_chat_group_with_related_data |
| 20261022094349 | delete_chat_session_content |
| 20261023092523 | restrict_postgres_public_sequence_defaults |
| 20261023092715 | revoke_anon_public_sequence_access |
| 20261023095003 | exclude_deleted_chat_from_character_turn_counts |
| 20261023111142 | guard_whisper_thread_cycles |
| 20261023112911 | allow_anon_rls_whisper_helper |
| 20261024002459 | guard_memory_photo_delete_during_pending_account_deletion |
| 20261024050120 | revoke_direct_profile_writes |

## Repository-only migration files

| Repo file prefix | Migration name |
|---:|---|
| 20261015151500 | optimize_rls_auth_initplan_policies |
| legacy | 20261015_character_soft_delete |
| legacy | 20261015_chat_session_character_access |
| legacy | 20261015_chat_turn_ledger_idempotency |
| legacy | 20261015_chat_turn_transaction_functions |
| legacy | 20261015_fix_reserve_chat_turn_conflict_target |
| 20261016003000 | guard_chat_turn_assistant_upsert |
| 20261017013000 | validate_group_name_length_constraint |
| 20261019100000 | add_chat_group_pinned |
| 20261020120000 | restrict_test_diamond_grant_rpc |
| 20261020150000 | soft_delete_memory_photo_rpc |
| 20261021090000 | public_character_turn_count |
| 20261024170000 | fix_owner_nsfw_character_read |
| 20261024180000 | fix_nsfw_public_rpc_age_gate |

## Known missing deletion migration sources

- 20261022094147_delete_chat_group_with_related_data
- 20261022094349_delete_chat_session_content
- Exact GitHub commit-history lookups for these paths returned no commits.
- PR #133 changed-file inventory contained only index.html; no SQL source artifact was present in that PR.

## Safe next steps

1. Capture an authoritative read-only schema snapshot of the live test project: columns/defaults, constraints, indexes, triggers, policies, function definitions and grants, Storage buckets and policies.
2. Build a disposable project from the current repository migrations and compare its schema to the live test project. If replay fails due duplicate prefixes or missing prerequisites, document the exact failure and stop.
3. If the replay chain is not recoverable, design a separately reviewed baseline reconciliation from a full schema snapshot and object-by-object provenance. Preserve existing data and test-project-only settings.
4. Only after baseline approval create executable chat lifecycle migrations. Do not manually edit schema_migrations or fabricate historical source.

## Scope and safety

- No DDL/DML, migration application, data mutation, worker deployment, or cron configuration was performed.
- Character illustration/video buckets are not chat cleanup targets.
- Chat deletion contract remains immediate soft-delete with 30-day retention, then permanent relational and Storage purge.
