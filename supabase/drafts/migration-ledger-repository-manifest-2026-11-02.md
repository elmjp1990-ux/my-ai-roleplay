# Migration ledger ↔ repository manifest — 2026-11-02

Repository: `elmjp1990-ux/my-ai-roleplay`  
Branch: `security/chat-deletion-lifecycle-reconciliation`  
Compared branch head: `941f1e1059fbf533c5857aa77bad270c5442dda6`  
Supabase test project: `ouyewoagbmtqehbofrje`  
Method: read-only migration ledger listing + recursive Git tree comparison. No migration SQL was executed.

## Summary

- Remote ledger records: **152**
- Repository migration SQL files: **107** (102 timestamp-prefixed, 5 legacy)
- Exact remote version + name match: **27**
- Remote records whose name exists in repo but version differs: **68**
- Remote migration names with no matching repository filename: **57**
- Repository migration files whose names are absent from remote ledger: **14**
- Unique timestamp versions in repo: **96**
- Duplicate timestamp collisions: **5 version values**

**Important correction to version-only interpretation:** 104 remote versions have no exact same-version file, but **68** of those migration names do exist in the repository under a different timestamp. These are filename/version drift, not proof that all 104 SQL sources are missing. Only **57** remote migration names have no matching local filename at all. The exact source content and commit provenance still need verification.

## Remote ledger mapping (match by name and version)

| Remote version | Remote migration name | Local same-name file(s) | Status |
|---|---|---|---|
| 20261015065943 | isolate_character_private_info | `supabase/migrations/20261016004515_isolate_character_private_info.sql` (v=20261016004515) | NAME MATCH / VERSION DRIFT |
| 20261015083242 | make_account_deletion_archive_idempotent | — | NO NAME MATCH |
| 20261015083812 | harden_handle_new_user_trigger | — | NO NAME MATCH |
| 20261015084226 | allow_safe_recovery_before_deletion_processing | — | NO NAME MATCH |
| 20261015101628 | wallet_chat_turn_charging | — | NO NAME MATCH |
| 20261015130752 | chat_session_character_access | — | NO NAME MATCH |
| 20261015133300 | chat_turn_transaction_functions | — | NO NAME MATCH |
| 20261015134109 | chat_turn_ledger_idempotency | — | NO NAME MATCH |
| 20261015141259 | group_chat_core_schema | `supabase/migrations/20261015141259_group_chat_core_schema.sql` (v=20261015141259) | EXACT |
| 20261015141609 | group_chat_mock_turns | `supabase/migrations/20261015141609_group_chat_mock_turns.sql` (v=20261015141609) | EXACT |
| 20261015141936 | group_chat_group_activity | `supabase/migrations/20261015141936_group_chat_group_activity.sql` (v=20261015141936) | EXACT |
| 20261015145637 | fix_reserve_chat_turn_conflict_target | — | NO NAME MATCH |
| 20261015150134 | guard_pending_deletion_group_activity | `supabase/migrations/20261015150500_guard_pending_deletion_group_activity.sql` (v=20261015150500) | NAME MATCH / VERSION DRIFT |
| 20261015150143 | add_missing_foreign_key_indexes | — | NO NAME MATCH |
| 20261015151600 | freeze_group_access_pending_deletion | `supabase/migrations/20261015151500_freeze_group_access_pending_deletion.sql` (v=20261015151500) | NAME MATCH / VERSION DRIFT |
| 20261015151939 | limit_deletion_archive_execution | `supabase/migrations/20261015163000_limit_deletion_archive_execution.sql` (v=20261015163000) | NAME MATCH / VERSION DRIFT |
| 20261015153429 | freeze_pending_account_character_writes | `supabase/migrations/20261015170000_freeze_pending_account_character_writes.sql` (v=20261015170000) | NAME MATCH / VERSION DRIFT |
| 20261015153435 | harden_character_soft_delete_helper_rpc | `supabase/migrations/20261015153500_harden_character_soft_delete_helper_rpc.sql` (v=20261015153500) | NAME MATCH / VERSION DRIFT |
| 20261015154311 | restore_account_deletion_grace_period | `supabase/migrations/20261015180000_restore_account_deletion_grace_period.sql` (v=20261015180000) | NAME MATCH / VERSION DRIFT |
| 20261015154925 | restore_test_account_deletion_five_minute_grace_period | `supabase/migrations/20261015190000_restore_test_account_deletion_five_minute_grace_period.sql` (v=20261015190000) | NAME MATCH / VERSION DRIFT |
| 20261016004515 | isolate_character_private_info | `supabase/migrations/20261016004515_isolate_character_private_info.sql` (v=20261016004515) | EXACT |
| 20261016091809 | enforce_shared_group_scene_mode | — | NO NAME MATCH |
| 20261016093844 | validate_shared_group_scene_mode_constraint | — | NO NAME MATCH |
| 20261016100806 | allow_users_to_read_own_chat_turn_charges | — | NO NAME MATCH |
| 20261016102307 | grant_select_chat_turn_charges_authenticated | — | NO NAME MATCH |
| 20261016103434 | restrict_group_creation_to_shared_scene | — | NO NAME MATCH |
| 20261016103450 | harden_shared_scene_input_validation | — | NO NAME MATCH |
| 20261016104121 | require_public_approved_characters_for_groups | — | NO NAME MATCH |
| 20261016104703 | remove_character_review_approval_gate | — | NO NAME MATCH |
| 20261016112636 | restrict_private_character_reads | — | NO NAME MATCH |
| 20261016112651 | restrict_story_reads_to_public_characters | — | NO NAME MATCH |
| 20261016140139 | limit_chat_group_name_to_25_chars | — | NO NAME MATCH |
| 20261017010838 | preserve_group_history_on_character_delete | — | NO NAME MATCH |
| 20261017010841 | account_deletion_grace_period_config | — | NO NAME MATCH |
| 20261017010847 | account_deletion_worker | — | NO NAME MATCH |
| 20261017035145 | guard_group_mock_turn_during_deletion | — | NO NAME MATCH |
| 20261017040730 | guard_snapshot_sync_during_deletion | — | NO NAME MATCH |
| 20261017100648 | chat_turn_existing_retry_recovery_order | — | NO NAME MATCH |
| 20261018005752 | persist_group_speaker_snapshot | `supabase/migrations/20261018005752_persist_group_speaker_snapshot.sql` (v=20261018005752) | EXACT |
| 20261018005846 | allow_snapshotted_group_speaker_without_character_fk | `supabase/migrations/20261018005846_allow_snapshotted_group_speaker_without_character_fk.sql` (v=20261018005846) | EXACT |
| 20261018015010 | add_group_player_persona_and_world_character | — | NO NAME MATCH |
| 20261018015631 | guard_character_rpcs_during_deletion | — | NO NAME MATCH |
| 20261018083612 | character_comments_cloud_rls | — | NO NAME MATCH |
| 20261018083915 | secure_comment_likes_visibility | — | NO NAME MATCH |
| 20261018084032 | tighten_comment_mutation_permissions | — | NO NAME MATCH |
| 20261018084237 | restrict_comment_table_grants | — | NO NAME MATCH |
| 20261018090441 | secure_whisper_comment_redaction | — | NO NAME MATCH |
| 20261018090505 | fix_whisper_safe_reads_and_reply_policy | — | NO NAME MATCH |
| 20261018090614 | harden_whisper_redaction_deleted_content | — | NO NAME MATCH |
| 20261018090636 | fix_anonymous_whisper_redaction | — | NO NAME MATCH |
| 20261018103025 | profiles_insert_own_row_rls_fix | — | NO NAME MATCH |
| 20261018103253 | wallet_ledger_character_name_lookup | — | NO NAME MATCH |
| 20261018103858 | persist_persona_presets_on_profiles | — | NO NAME MATCH |
| 20261018115226 | add_profile_birthdate | — | NO NAME MATCH |
| 20261018150329 | test_grant_diamonds_200_once | `supabase/migrations/20261018150500_test_grant_diamonds_200_once.sql` (v=20261018150500) | NAME MATCH / VERSION DRIFT |
| 20261018151424 | daily_checkin_silver_reward_cycle | `supabase/migrations/20261018162000_daily_checkin_silver_reward_cycle.sql` (v=20261018162000) | NAME MATCH / VERSION DRIFT |
| 20261019123547 | create_private_personax_memory_photo_storage | — | NO NAME MATCH |
| 20261020014442 | limit_public_profile_select_columns | `supabase/migrations/20261020014442_limit_public_profile_select_columns.sql` (v=20261020014442) | EXACT |
| 20261020015530 | revoke_anonymous_profile_writes | `supabase/migrations/20261020015530_revoke_anonymous_profile_writes.sql` (v=20261020015530) | EXACT |
| 20261020022052 | get_own_private_profile_data | `supabase/migrations/20261020022052_get_own_private_profile_data.sql` (v=20261020022052) | EXACT |
| 20261020045948 | unified_memory_album | `supabase/migrations/20261020120000_unified_memory_album.sql` (v=20261020120000) | NAME MATCH / VERSION DRIFT |
| 20261020050258 | memory_album_fk_indexes | `supabase/migrations/20261020123000_memory_album_fk_indexes.sql` (v=20261020123000) | NAME MATCH / VERSION DRIFT |
| 20261020052245 | memory_album_owner_updates | `supabase/migrations/20261020140000_memory_album_owner_updates.sql` (v=20261020140000) | NAME MATCH / VERSION DRIFT |
| 20261020054843 | fix_memory_album_mutation_permissions_and_group_storage_policy | — | NO NAME MATCH |
| 20261020061836 | secure_memory_photo_soft_delete_rpc | — | NO NAME MATCH |
| 20261020132412 | group_background_unified_album | `supabase/migrations/20261020132412_group_background_unified_album.sql` (v=20261020132412) | EXACT |
| 20261021023530 | include_group_turns_in_character_counts | `supabase/migrations/20261021110000_include_group_turns_in_character_counts.sql` (v=20261021110000) | NAME MATCH / VERSION DRIFT |
| 20261021044230 | allow_group_owner_edit_message_content | `supabase/migrations/20261021044230_allow_group_owner_edit_message_content.sql` (v=20261021044230) | EXACT |
| 20261021051029 | group_message_soft_delete | `supabase/migrations/20261021050000_group_message_soft_delete.sql` (v=20261021050000) | NAME MATCH / VERSION DRIFT |
| 20261021062949 | allow_group_message_soft_delete | `supabase/migrations/20261021060000_allow_group_message_soft_delete.sql` (v=20261021060000) | NAME MATCH / VERSION DRIFT |
| 20261021093628 | add_character_phone_settings | `supabase/migrations/20261021100000_add_character_phone_settings.sql` (v=20261021100000) | NAME MATCH / VERSION DRIFT |
| 20261022055143 | create_group_sweet_diary_cloud_sync | `supabase/migrations/20261022130000_create_group_sweet_diary_cloud_sync.sql` (v=20261022130000) | NAME MATCH / VERSION DRIFT |
| 20261022055439 | index_group_sweet_diary_owner | `supabase/migrations/20261022130100_index_group_sweet_diary_owner.sql` (v=20261022130100) | NAME MATCH / VERSION DRIFT |
| 20261022064137 | author_follow_tracking | — | NO NAME MATCH |
| 20261022065558 | character_nsfw_workplace_warning | — | NO NAME MATCH |
| 20261022072751 | grant_public_profile_columns_select | — | NO NAME MATCH |
| 20261022072918 | secure_public_profiles_and_restore_profile_reads | — | NO NAME MATCH |
| 20261022073159 | limit_public_profiles_view_to_select_only | — | NO NAME MATCH |
| 20261022094147 | delete_chat_group_with_related_data | — | NO NAME MATCH |
| 20261022094349 | delete_chat_session_content | — | NO NAME MATCH |
| 20261022173642 | secure_character_turn_count_visibility | `supabase/migrations/20261022173642_secure_character_turn_count_visibility.sql` (v=20261022173642) | EXACT |
| 20261022175412 | sync_group_character_snapshots_on_delete_and_update | `supabase/migrations/20261022175412_sync_group_character_snapshots_on_delete_and_update.sql` (v=20261022175412) | EXACT |
| 20261022180019 | backfill_deleted_character_chat_snapshots | `supabase/migrations/20261023013000_backfill_deleted_character_chat_snapshots.sql` (v=20261023013000) | NAME MATCH / VERSION DRIFT |
| 20261022180206 | secure_public_profiles_invoker_and_column_grants | `supabase/migrations/20261023014500_secure_public_profiles_invoker_and_column_grants.sql` (v=20261023014500) | NAME MATCH / VERSION DRIFT |
| 20261022182628 | save_my_profile_owner_checked_rpc | `supabase/migrations/20261023030000_save_my_profile_owner_checked_rpc.sql` (v=20261023030000) | NAME MATCH / VERSION DRIFT |
| 20261022185425 | exclude_deleted_group_messages_from_turn_counts | `supabase/migrations/20261023120000_exclude_deleted_group_messages_from_turn_counts.sql` (v=20261023120000) | NAME MATCH / VERSION DRIFT |
| 20261022233024 | fix_group_memory_photo_storage_read_policy | `supabase/migrations/20261022233024_fix_group_memory_photo_storage_read_policy.sql` (v=20261022233024) | EXACT |
| 20261023012000 | group_chat_billing_per_character | `supabase/migrations/20261023012000_group_chat_billing_per_character.sql` (v=20261023012000) | EXACT |
| 20261023035710 | group_chat_billing_per_character | `supabase/migrations/20261023012000_group_chat_billing_per_character.sql` (v=20261023012000) | NAME MATCH / VERSION DRIFT |
| 20261023092154 | restrict_public_default_privileges | `supabase/migrations/20261023040000_restrict_public_default_privileges.sql` (v=20261023040000) | NAME MATCH / VERSION DRIFT |
| 20261023092523 | restrict_postgres_public_sequence_defaults | — | NO NAME MATCH |
| 20261023092715 | revoke_anon_public_sequence_access | — | NO NAME MATCH |
| 20261023095003 | exclude_deleted_chat_from_character_turn_counts | `supabase/migrations/20261023095003_exclude_deleted_chat_from_character_turn_counts.sql` (v=20261023095003) | EXACT |
| 20261023104741 | protect_whisper_reply_direct_select | `supabase/migrations/20261023120000_protect_whisper_reply_direct_select.sql` (v=20261023120000) | NAME MATCH / VERSION DRIFT |
| 20261023111142 | guard_whisper_thread_cycles | — | NO NAME MATCH |
| 20261023112911 | allow_anon_rls_whisper_helper | — | NO NAME MATCH |
| 20261023122555 | fix_safe_comment_rpc_whisper_ancestry | `supabase/migrations/20261023123000_fix_safe_comment_rpc_whisper_ancestry.sql` (v=20261023123000) | NAME MATCH / VERSION DRIFT |
| 20261024002459 | guard_memory_photo_delete_during_pending_account_deletion | — | NO NAME MATCH |
| 20261024050120 | revoke_direct_profile_writes | — | NO NAME MATCH |
| 20261024061142 | fix_whisper_reply_ancestry_authorization | `supabase/migrations/20261024090000_fix_whisper_reply_ancestry_authorization.sql` (v=20261024090000) | NAME MATCH / VERSION DRIFT |
| 20261024073819 | character_nsfw_terms_and_age_gate | `supabase/migrations/20261024153000_character_nsfw_terms_and_age_gate.sql` (v=20261024153000) | NAME MATCH / VERSION DRIFT |
| 20261024073923 | character_avatar_video_storage | `supabase/migrations/20261024154000_character_avatar_video_storage.sql` (v=20261024154000) | NAME MATCH / VERSION DRIFT |
| 20261024074821 | fix_character_nsfw_rls_and_video_read | `supabase/migrations/20261024160000_fix_character_nsfw_rls_and_video_read.sql` (v=20261024160000) | NAME MATCH / VERSION DRIFT |
| 20261024074938 | enforce_character_video_owner_path | `supabase/migrations/20261024161000_enforce_character_video_owner_path.sql` (v=20261024161000) | NAME MATCH / VERSION DRIFT |
| 20261024075220 | move_adult_check_to_private_schema | `supabase/migrations/20261024162000_move_adult_check_to_private_schema.sql` (v=20261024162000) | NAME MATCH / VERSION DRIFT |
| 20261024083626 | enforce_nsfw_age_gate_for_character_reads | `supabase/migrations/20261024170000_enforce_nsfw_age_gate_for_character_reads.sql` (v=20261024170000) | NAME MATCH / VERSION DRIFT |
| 20261028034854 | encounter_mode_core_schema | `supabase/migrations/20261028120000_encounter_mode_core_schema.sql` (v=20261028120000) | NAME MATCH / VERSION DRIFT |
| 20261028055543 | atomic_encounter_schedule_sync | `supabase/migrations/20261028143000_atomic_encounter_schedule_sync.sql` (v=20261028143000) | NAME MATCH / VERSION DRIFT |
| 20261028072202 | trusted_encounter_interaction | `supabase/migrations/20261028160000_trusted_encounter_interaction.sql` (v=20261028160000) | NAME MATCH / VERSION DRIFT |
| 20261028072315 | safe_encounter_schedule_resolver | `supabase/migrations/20261028163000_safe_encounter_schedule_resolver.sql` (v=20261028163000) | NAME MATCH / VERSION DRIFT |
| 20261028075129 | trusted_chat_mode_marker | `supabase/migrations/20261028170000_trusted_chat_mode_marker.sql` (v=20261028170000) | NAME MATCH / VERSION DRIFT |
| 20261028080237 | enforce_trusted_chat_mode | `supabase/migrations/20261028173000_enforce_trusted_chat_mode.sql` (v=20261028173000) | NAME MATCH / VERSION DRIFT |
| 20261028080945 | encounter_session_access_check | `supabase/migrations/20261028180000_encounter_session_access_check.sql` (v=20261028180000) | NAME MATCH / VERSION DRIFT |
| 20261028103534 | idempotent_encounter_turn_interaction | `supabase/migrations/20261028190000_idempotent_encounter_turn_interaction.sql` (v=20261028190000) | NAME MATCH / VERSION DRIFT |
| 20261028120032 | prevent_duplicate_chat_message_charges | `supabase/migrations/20261028193000_prevent_duplicate_chat_message_charges.sql` (v=20261028193000) | NAME MATCH / VERSION DRIFT |
| 20261029011336 | allow_all_eligible_public_encounter_schedules | `supabase/migrations/20261029120000_allow_all_eligible_public_encounter_schedules.sql` (v=20261029120000) | NAME MATCH / VERSION DRIFT |
| 20261029034207 | allow_all_eligible_encounter_sessions | `supabase/migrations/20261029034207_allow_all_eligible_encounter_sessions.sql` (v=20261029034207) | EXACT |
| 20261029224513 | validate_settled_encounter_interaction | `supabase/migrations/20261029210000_validate_settled_encounter_interaction.sql` (v=20261029210000) | NAME MATCH / VERSION DRIFT |
| 20261030213037 | affinity_system_foundation | `supabase/migrations/20261030120000_affinity_system_foundation.sql` (v=20261030120000) | NAME MATCH / VERSION DRIFT |
| 20261030215321 | encounter_turn_evidence_writer | `supabase/migrations/20261031120000_encounter_turn_evidence_writer.sql` (v=20261031120000) | NAME MATCH / VERSION DRIFT |
| 20261030222510 | encounter_scene_settlement | `supabase/migrations/20261031150000_encounter_scene_settlement.sql` (v=20261031150000) | NAME MATCH / VERSION DRIFT |
| 20261030222553 | block_expired_encounter_turns | `supabase/migrations/20261031160000_block_expired_encounter_turns.sql` (v=20261031160000) | NAME MATCH / VERSION DRIFT |
| 20261030224826 | atomic_encounter_turn_reservation | `supabase/migrations/20261031170000_atomic_encounter_turn_reservation.sql` (v=20261031170000) | NAME MATCH / VERSION DRIFT |
| 20261030224911 | allow_preexpiry_reserved_turn_completion | `supabase/migrations/20261031180000_allow_preexpiry_reserved_turn_completion.sql` (v=20261031180000) | NAME MATCH / VERSION DRIFT |
| 20261030230919 | encounter_session_pause_resume | `supabase/migrations/20261031190000_encounter_session_pause_resume.sql` (v=20261031190000) | NAME MATCH / VERSION DRIFT |
| 20261031010419 | allow_preexpiry_encounter_retry | `supabase/migrations/20261031200000_allow_preexpiry_encounter_retry.sql` (v=20261031200000) | NAME MATCH / VERSION DRIFT |
| 20261031010515 | fix_encounter_retry_charge_lookup | `supabase/migrations/20261031210000_fix_encounter_retry_charge_lookup.sql` (v=20261031210000) | NAME MATCH / VERSION DRIFT |
| 20261031010719 | restrict_encounter_retry_lifecycle_states | `supabase/migrations/20261031220000_restrict_encounter_retry_lifecycle_states.sql` (v=20261031220000) | NAME MATCH / VERSION DRIFT |
| 20261031011247 | validate_story_batch_turn_sources | `supabase/migrations/20261031230000_validate_story_batch_turn_sources.sql` (v=20261031230000) | NAME MATCH / VERSION DRIFT |
| 20261031011426 | encounter_evaluation_dispatch_queue | `supabase/migrations/20261031240000_encounter_evaluation_dispatch_queue.sql` (v=20261031240000) | NAME MATCH / VERSION DRIFT |
| 20261031011509 | bound_encounter_evaluation_retries | `supabase/migrations/20261031250000_bound_encounter_evaluation_retries.sql` (v=20261031250000) | NAME MATCH / VERSION DRIFT |
| 20261031011944 | latest_settled_encounter_for_story | `supabase/migrations/20261031260000_latest_settled_encounter_for_story.sql` (v=20261031260000) | NAME MATCH / VERSION DRIFT |
| 20261031012300 | story_relationship_state_read_rpc | `supabase/migrations/20261031270000_story_relationship_state_read_rpc.sql` (v=20261031270000) | NAME MATCH / VERSION DRIFT |
| 20261031021650 | city_character_affinity_display | `supabase/migrations/20261031280000_city_character_affinity_display.sql` (v=20261031280000) | NAME MATCH / VERSION DRIFT |
| 20261031033312 | character_illustration_storage | `supabase/migrations/20261031100000_character_illustration_storage.sql` (v=20261031100000) | NAME MATCH / VERSION DRIFT |
| 20261031033429 | fix_character_illustration_storage_policy_paths | `supabase/migrations/20261031103000_fix_character_illustration_storage_policy_paths.sql` (v=20261031103000) | NAME MATCH / VERSION DRIFT |
| 20261031055744 | character_illustration_display_names | `supabase/migrations/20261031120000_character_illustration_display_names.sql` (v=20261031120000) | NAME MATCH / VERSION DRIFT |
| 20261031110122 | author_encounter_schedule_descriptions | `supabase/migrations/20261031120000_author_encounter_schedule_descriptions.sql` (v=20261031120000) | NAME MATCH / VERSION DRIFT |
| 20261031110247 | index_author_encounter_schedule_descriptions | `supabase/migrations/20261031120500_index_author_encounter_schedule_descriptions.sql` (v=20261031120500) | NAME MATCH / VERSION DRIFT |
| 20261031131524 | character_illustration_cleanup_queue | `supabase/migrations/20261031211200_character_illustration_cleanup_queue.sql` (v=20261031211200) | NAME MATCH / VERSION DRIFT |
| 20261031131654 | fix_character_illustration_cleanup_path_check | `supabase/migrations/20261031212000_fix_character_illustration_cleanup_path_check.sql` (v=20261031212000) | NAME MATCH / VERSION DRIFT |
| 20261101052444 | chat_deletion_queue_foundation | `supabase/migrations/20261101052444_chat_deletion_queue_foundation.sql` (v=20261101052444) | EXACT |
| 20261101052951 | chat_soft_delete_lifecycle | `supabase/migrations/20261101052951_chat_soft_delete_lifecycle.sql` (v=20261101052951) | EXACT |
| 20261101053732 | chat_writer_parent_first_guards | `supabase/migrations/20261101053732_chat_writer_parent_first_guards.sql` (v=20261101053732) | EXACT |
| 20261101054027 | encounter_chat_deletion_gates | `supabase/migrations/20261101054027_encounter_chat_deletion_gates.sql` (v=20261101054027) | EXACT |
| 20261101054353 | chat_memory_storage_lifecycle_policies | `supabase/migrations/20261101054353_chat_memory_storage_lifecycle_policies.sql` (v=20261101054353) | EXACT |
| 20261101054423 | fix_chat_memory_storage_insert_path | `supabase/migrations/20261101054423_fix_chat_memory_storage_insert_path.sql` (v=20261101054423) | EXACT |
| 20261101055617 | chat_deletion_purge_worker_rpc | `supabase/migrations/20261101055617_chat_deletion_purge_worker_rpc.sql` (v=20261101055617) | EXACT |
| 20261101055901 | fix_group_turn_content_purge_marker | `supabase/migrations/20261101055901_fix_group_turn_content_purge_marker.sql` (v=20261101055901) | EXACT |
| 20261101060225 | preserve_wallet_character_label_after_chat_purge | `supabase/migrations/20261101060225_preserve_wallet_character_label_after_chat_purge.sql` (v=20261101060225) | EXACT |
| 20261101101343 | enable_pg_net_for_chat_deletion_worker | `supabase/migrations/20261101101343_enable_pg_net_for_chat_deletion_worker.sql` (v=20261101101343) | EXACT |
| 20261101110211 | account_deletion_character_video_storage_gates | — | NO NAME MATCH |

## Repository files with no same-name remote ledger entry

| Repository file | Local version | Git blob SHA |
|---|---|---|
| `supabase/migrations/20261015151500_optimize_rls_auth_initplan_policies.sql` | 20261015151500 | `20b9b381732668a444b7037ff791376fb2d5b64a` |
| `supabase/migrations/20261015_character_soft_delete.sql` | legacy | `9fedc459098f9bd1fd9ac9842908b79b99c1faaf` |
| `supabase/migrations/20261015_chat_session_character_access.sql` | legacy | `ab218c3820b3d4ba481f39e6c2181d228bf05ff0` |
| `supabase/migrations/20261015_chat_turn_ledger_idempotency.sql` | legacy | `fc43672d9d511632d6c3db53c4ce7627dde547b4` |
| `supabase/migrations/20261015_chat_turn_transaction_functions.sql` | legacy | `ebf0dc0e7959c8d63ecfe681cdc99e0b3abac0f6` |
| `supabase/migrations/20261015_fix_reserve_chat_turn_conflict_target.sql` | legacy | `ed2f671457801fc08fe6a404ed4234f3bdf20c0a` |
| `supabase/migrations/20261016003000_guard_chat_turn_assistant_upsert.sql` | 20261016003000 | `2b9173aff70f105cf9957f83632471b468a7808c` |
| `supabase/migrations/20261017013000_validate_group_name_length_constraint.sql` | 20261017013000 | `89a0ebe37f638996b44e0f0191e47ca947d04d4c` |
| `supabase/migrations/20261019100000_add_chat_group_pinned.sql` | 20261019100000 | `047bff73d11ca4daee876707616225ac2bf3ce35` |
| `supabase/migrations/20261020120000_restrict_test_diamond_grant_rpc.sql` | 20261020120000 | `36a45241581a25f8d6bf7f7fdc4fe9b9c896336e` |
| `supabase/migrations/20261020150000_soft_delete_memory_photo_rpc.sql` | 20261020150000 | `4a1f1979d92dad42847c3ba3548577c99f26166a` |
| `supabase/migrations/20261021090000_public_character_turn_count.sql` | 20261021090000 | `9ca222e68f717825f474cfba3eb03cd3fc8bc1b5` |
| `supabase/migrations/20261024170000_fix_owner_nsfw_character_read.sql` | 20261024170000 | `b9bfd1a058285105c7e14ccad205244cc06bce66` |
| `supabase/migrations/20261024180000_fix_nsfw_public_rpc_age_gate.sql` | 20261024180000 | `e75adf30d5fda0959747a963fa575617ebdca334` |

## Duplicate timestamp collisions

- `20261015151500`: `supabase/migrations/20261015151500_freeze_group_access_pending_deletion.sql`, `supabase/migrations/20261015151500_optimize_rls_auth_initplan_policies.sql`
- `20261020120000`: `supabase/migrations/20261020120000_restrict_test_diamond_grant_rpc.sql`, `supabase/migrations/20261020120000_unified_memory_album.sql`
- `20261023120000`: `supabase/migrations/20261023120000_exclude_deleted_group_messages_from_turn_counts.sql`, `supabase/migrations/20261023120000_protect_whisper_reply_direct_select.sql`
- `20261024170000`: `supabase/migrations/20261024170000_enforce_nsfw_age_gate_for_character_reads.sql`, `supabase/migrations/20261024170000_fix_owner_nsfw_character_read.sql`
- `20261031120000`: `supabase/migrations/20261031120000_author_encounter_schedule_descriptions.sql`, `supabase/migrations/20261031120000_character_illustration_display_names.sql`, `supabase/migrations/20261031120000_encounter_turn_evidence_writer.sql`

## Findings / reconciliation rules

- Remote ledger records and repository files must be compared by **both** version and migration name. A version-only comparison overstates missing source files where the same migration name was renamed to a different timestamp.
- Example: remote `20261015065943 / isolate_character_private_info` has no exact same-version file, but the repo contains `20261016004515_isolate_character_private_info.sql`; the remote ledger also contains a separate `20261016004515 / isolate_character_private_info` record. This indicates duplicate same-name history with different versions; it does not prove the first source SQL is identical to the second.
- A same-name match is only a candidate mapping. Compare SQL content, commit history, and authoritative applied source before declaring it recovered.
- Remote migration names with no local same-name file may have been manually applied, renamed to another name, or omitted. Recover provenance before creating replacement migrations.
- Repository-only names may be unapplied, abandoned, or a local alternate. Do not apply them to the hosted test project until reconciled.
- Duplicate local timestamps make clean replay invalid/ambiguous and require deliberate resolution in a new clean-room baseline strategy.
- Do not change hosted `supabase_migrations.schema_migrations`, run hosted `db reset`, or use `db push` to bypass these mismatches.
- The site has no real users and is test-only, so a disposable-local consolidated baseline may be evaluated; label it clearly as a reconstruction, not original migration provenance.

## Next step

Build a per-migration provenance matrix for the 57 remote names without local counterparts, the 68 same-name/version-drift pairs, and 14 repository-only names. Use Git commit history and available SQL sources to distinguish renamed files from missing/manual migrations before changing migration files.


## Cross-branch source recovery (selected branch scan)

A follow-up read-only scan examined 38 selected repository branches with migration-heavy or security-related names, including account-deletion, group-chat, wallet, encounter, privacy, and RLS branches. This is a bounded scan, not every branch/history object.

### Candidate source files recovered outside the current PR branch

| Remote ledger version/name | Candidate branch | Candidate file | Git blob SHA | Assessment |
|---|---|---|---|---|
| `20261017010838 / preserve_group_history_on_character_delete` | `fix/account-deletion-ready` | `20261017010838_preserve_group_history_on_character_delete.sql` | `628b6a6ecf56962b64bdc1764d04b81d8687c4c0` | Exact version + name candidate |
| `20261017010841 / account_deletion_grace_period_config` | `fix/account-deletion-ready` | `20261017010841_account_deletion_grace_period_config.sql` | `664c30ff901817050cacb86f67bc0a84986f9dac` | Exact version + name candidate |
| `20261017010847 / account_deletion_worker` | `fix/account-deletion-ready` | `20261017010847_account_deletion_worker.sql` | `1e329c68a40f5ada56bf7dd47f9b64bf45a77367` | Exact version + name candidate |
| `20261017035145 / guard_group_mock_turn_during_deletion` | `fix/account-deletion-ready` | `20261017035145_guard_group_mock_turn_during_deletion.sql` | `730e8d037d79f6718728ef8dc77bd90372477a7c` | Exact version + name candidate |
| `20261017040730 / guard_snapshot_sync_during_deletion` | `fix/account-deletion-ready` | `20261017040730_guard_snapshot_sync_during_deletion.sql` | `25f46d7163589c9d4c97caf155e43ebf05a85d08` | Exact version + name candidate |
| `20261018015631 / guard_character_rpcs_during_deletion` | `fix/account-deletion-ready` | `20261017043000_guard_character_rpcs_during_deletion.sql` | `94ade7da6a2fa3adcf89217c2fc44176e58dfcb7` | Same-name candidate; version differs and requires SQL/commit provenance comparison |

Additional older variants:
- `fix/account-deletion-worker` contains same-name `account_deletion_grace_period_config`, `account_deletion_worker`, and `preserve_group_history_on_character_delete` files under earlier versions (`20261015110000`, `20261015120000`, `20261017110000`). Prefer neither automatically; compare to the exact remote version candidate and commit history.
- `fix/account-deletion-deadline-config` also contains an earlier `account_deletion_grace_period_config` version.

### Interpretation

- The five exact version + name candidates above are useful source-recovery evidence, but their SQL still must be reviewed for content, dependencies, and consistency with current code before copying into the PR branch.
- The sixth candidate is a same-name/different-version variant and must not be relabeled as the remote source without proving the SQL matches.
- 51 of the 57 remote-only migration names were not found in this selected branch scan. This does not prove they are absent from all Git history or private/manual SQL sources.
- Do not copy these historical files into the active migration directory or replay them until the complete order, dependencies, duplicate timestamps, and current architecture have been reconciled.


## Source commit provenance and safety review

The branch-specific GitHub commit history was checked for the five recovered files. These are source additions/filename-alignment commits, not proof that the current active branch should replay them unchanged.

| File | Source commit | Commit message / date | Evidence |
|---|---|---|---|
| `20261017010838_preserve_group_history_on_character_delete.sql` | `7a993d0af80d34d194228823cbbb3ea5493ca157` | `chore: align migration filename with applied test migration version` — 2026-10-17 01:10:53Z | Commit adds 86-line migration |
| `20261017010841_account_deletion_grace_period_config.sql` | `d7768435c9e7b2552816a2282efee26367c4430e` | `chore: align migration filename with applied test migration version` — 2026-10-17 01:10:58Z | Commit adds 50-line migration |
| `20261017010847_account_deletion_worker.sql` | `e8ecf796c105db3aac9e79beb6b2d369236b766e` | `chore: align migration filename with applied test migration version` — 2026-10-17 01:11:03Z | Commit adds 395-line migration; later comment-only rollout wording change in `af34cf3bed63182adf1cfe9c82b792d3c5d6421b` |
| `20261017035145_guard_group_mock_turn_during_deletion.sql` | `a855de8680542ea18da8c79122f076b0b1f85df2` | `Align group-turn guard migration filename with test DB history` — 2026-10-17 05:37:58Z | Commit adds 121-line migration |
| `20261017040730_guard_snapshot_sync_during_deletion.sql` | `81fe5d5ba749a7d19169c6eee6cec251a09d4356` | `Align snapshot-sync guard migration filename with test DB history` — 2026-10-17 05:38:01Z | Commit adds 54-line migration |

### Safety findings from recovered SQL

- **Account deletion worker migration is not safe as the final implementation under the current user-approved requirements.** Its `prepare_account_deletion(p_user_id)` archives selected financial/chat evidence, then deletes `ai_generation_records`, owned message versions, `chat_turn_charges`, `wallet_transactions`, and the account's legacy `conversations`; it relies on profile/character CASCADE relationships for further cleanup. It does not preserve and detach all character rows, private settings, schedules, stories, illustration metadata, avatar video references, and historical creator attribution. Do not re-enable this worker or replay it as the final deletion design.
- `preserve_group_history_on_character_delete` backfills `speaker_snapshot`, makes group member/message `character_id` nullable, and changes those FKs to `ON DELETE SET NULL`. This preserves group speaker display data but does not by itself satisfy single-chat, encounter/story, media, or durable creator-attribution requirements.
- `account_deletion_grace_period_config` intentionally does not seed a grace period and makes the request RPC fail closed until the environment has a setting. Keep environment-specific timing out of the migration source.
- `guard_group_mock_turn_during_deletion` protects a legacy mock group-turn RPC with account-active, owner, and idempotency checks; confirm whether any live frontend path still uses it before treating it as part of the new canonical chat model.
- `guard_snapshot_sync_during_deletion` requires the authenticated character author and blocks pending deletion, but updates snapshots for every `chat_sessions` row for that character. Integrate only after verifying the new existing-session snapshot/continuation rules; it is not a replacement for durable ownership detachment.

These recovered files are retained as historical source evidence only. No file was copied into `supabase/migrations/`, and no hosted or local migration was executed.
