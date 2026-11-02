# Migration ledger ↔ repository manifest — 2026-11-02

Repository: `elmjp1990-ux/my-ai-roleplay`  
Branch: `security/chat-deletion-lifecycle-reconciliation`  
Compared branch tree commit: `28a12cced2bb0fd1fe0698c895e1efe837d4741b`  
Supabase test project: `ouyewoagbmtqehbofrje`  
Method: read-only migration ledger listing + recursive Git tree comparison. No migration SQL was executed.

## Summary

- Remote ledger records: **152**
- Timestamp-prefixed repository migration files: **102**
- Unique timestamp versions in repository: **96**
- Remote versions with exactly one matching repository file: **27**
- Remote versions with no matching repository file: **125**
- Remote versions with multiple matching repository files: **0**
- Repository timestamp versions absent from remote ledger: **0**
- Legacy non-timestamp migration files: **5**

## Remote ledger mapping

| Remote version | Remote migration name | Repository file(s) | Status |
|---|---|---|---|
| 20261015065943 | isolate_character_private_info | **MISSING** | no tracked file |
| 20261015083242 | make_account_deletion_archive_idempotent | **MISSING** | no tracked file |
| 20261015083812 | harden_handle_new_user_trigger | **MISSING** | no tracked file |
| 20261015084226 | allow_safe_recovery_before_deletion_processing | **MISSING** | no tracked file |
| 20261015101628 | wallet_chat_turn_charging | **MISSING** | no tracked file |
| 20261015130752 | chat_session_character_access | **MISSING** | no tracked file |
| 20261015133300 | chat_turn_transaction_functions | **MISSING** | no tracked file |
| 20261015134109 | chat_turn_ledger_idempotency | **MISSING** | no tracked file |
| 20261015141259 | group_chat_core_schema | `supabase/migrations/20261015141259_group_chat_core_schema.sql` | matched |
| 20261015141609 | group_chat_mock_turns | `supabase/migrations/20261015141609_group_chat_mock_turns.sql` | matched |
| 20261015141936 | group_chat_group_activity | `supabase/migrations/20261015141936_group_chat_group_activity.sql` | matched |
| 20261015145637 | fix_reserve_chat_turn_conflict_target | **MISSING** | no tracked file |
| 20261015150134 | guard_pending_deletion_group_activity | **MISSING** | no tracked file |
| 20261015150143 | add_missing_foreign_key_indexes | **MISSING** | no tracked file |
| 20261015151600 | freeze_group_access_pending_deletion | **MISSING** | no tracked file |
| 20261015151939 | limit_deletion_archive_execution | **MISSING** | no tracked file |
| 20261015153429 | freeze_pending_account_character_writes | **MISSING** | no tracked file |
| 20261015153435 | harden_character_soft_delete_helper_rpc | **MISSING** | no tracked file |
| 20261015154311 | restore_account_deletion_grace_period | **MISSING** | no tracked file |
| 20261015154925 | restore_test_account_deletion_five_minute_grace_period | **MISSING** | no tracked file |
| 20261016004515 | isolate_character_private_info | `supabase/migrations/20261016004515_isolate_character_private_info.sql` | matched |
| 20261016091809 | enforce_shared_group_scene_mode | **MISSING** | no tracked file |
| 20261016093844 | validate_shared_group_scene_mode_constraint | **MISSING** | no tracked file |
| 20261016100806 | allow_users_to_read_own_chat_turn_charges | **MISSING** | no tracked file |
| 20261016102307 | grant_select_chat_turn_charges_authenticated | **MISSING** | no tracked file |
| 20261016103434 | restrict_group_creation_to_shared_scene | **MISSING** | no tracked file |
| 20261016103450 | harden_shared_scene_input_validation | **MISSING** | no tracked file |
| 20261016104121 | require_public_approved_characters_for_groups | **MISSING** | no tracked file |
| 20261016104703 | remove_character_review_approval_gate | **MISSING** | no tracked file |
| 20261016112636 | restrict_private_character_reads | **MISSING** | no tracked file |
| 20261016112651 | restrict_story_reads_to_public_characters | **MISSING** | no tracked file |
| 20261016140139 | limit_chat_group_name_to_25_chars | **MISSING** | no tracked file |
| 20261017010838 | preserve_group_history_on_character_delete | **MISSING** | no tracked file |
| 20261017010841 | account_deletion_grace_period_config | **MISSING** | no tracked file |
| 20261017010847 | account_deletion_worker | **MISSING** | no tracked file |
| 20261017035145 | guard_group_mock_turn_during_deletion | **MISSING** | no tracked file |
| 20261017040730 | guard_snapshot_sync_during_deletion | **MISSING** | no tracked file |
| 20261017100648 | chat_turn_existing_retry_recovery_order | **MISSING** | no tracked file |
| 20261018005752 | persist_group_speaker_snapshot | `supabase/migrations/20261018005752_persist_group_speaker_snapshot.sql` | matched |
| 20261018005846 | allow_snapshotted_group_speaker_without_character_fk | `supabase/migrations/20261018005846_allow_snapshotted_group_speaker_without_character_fk.sql` | matched |
| 20261018015010 | add_group_player_persona_and_world_character | **MISSING** | no tracked file |
| 20261018015631 | guard_character_rpcs_during_deletion | **MISSING** | no tracked file |
| 20261018083612 | character_comments_cloud_rls | **MISSING** | no tracked file |
| 20261018083915 | secure_comment_likes_visibility | **MISSING** | no tracked file |
| 20261018084032 | tighten_comment_mutation_permissions | **MISSING** | no tracked file |
| 20261018084237 | restrict_comment_table_grants | **MISSING** | no tracked file |
| 20261018090441 | secure_whisper_comment_redaction | **MISSING** | no tracked file |
| 20261018090505 | fix_whisper_safe_reads_and_reply_policy | **MISSING** | no tracked file |
| 20261018090614 | harden_whisper_redaction_deleted_content | **MISSING** | no tracked file |
| 20261018090636 | fix_anonymous_whisper_redaction | **MISSING** | no tracked file |
| 20261018103025 | profiles_insert_own_row_rls_fix | **MISSING** | no tracked file |
| 20261018103253 | wallet_ledger_character_name_lookup | **MISSING** | no tracked file |
| 20261018103858 | persist_persona_presets_on_profiles | **MISSING** | no tracked file |
| 20261018115226 | add_profile_birthdate | **MISSING** | no tracked file |
| 20261018150329 | test_grant_diamonds_200_once | **MISSING** | no tracked file |
| 20261018151424 | daily_checkin_silver_reward_cycle | **MISSING** | no tracked file |
| 20261019123547 | create_private_personax_memory_photo_storage | **MISSING** | no tracked file |
| 20261020014442 | limit_public_profile_select_columns | `supabase/migrations/20261020014442_limit_public_profile_select_columns.sql` | matched |
| 20261020015530 | revoke_anonymous_profile_writes | `supabase/migrations/20261020015530_revoke_anonymous_profile_writes.sql` | matched |
| 20261020022052 | get_own_private_profile_data | `supabase/migrations/20261020022052_get_own_private_profile_data.sql` | matched |
| 20261020045948 | unified_memory_album | **MISSING** | no tracked file |
| 20261020050258 | memory_album_fk_indexes | **MISSING** | no tracked file |
| 20261020052245 | memory_album_owner_updates | **MISSING** | no tracked file |
| 20261020054843 | fix_memory_album_mutation_permissions_and_group_storage_policy | **MISSING** | no tracked file |
| 20261020061836 | secure_memory_photo_soft_delete_rpc | **MISSING** | no tracked file |
| 20261020132412 | group_background_unified_album | `supabase/migrations/20261020132412_group_background_unified_album.sql` | matched |
| 20261021023530 | include_group_turns_in_character_counts | **MISSING** | no tracked file |
| 20261021044230 | allow_group_owner_edit_message_content | `supabase/migrations/20261021044230_allow_group_owner_edit_message_content.sql` | matched |
| 20261021051029 | group_message_soft_delete | **MISSING** | no tracked file |
| 20261021062949 | allow_group_message_soft_delete | **MISSING** | no tracked file |
| 20261021093628 | add_character_phone_settings | **MISSING** | no tracked file |
| 20261022055143 | create_group_sweet_diary_cloud_sync | **MISSING** | no tracked file |
| 20261022055439 | index_group_sweet_diary_owner | **MISSING** | no tracked file |
| 20261022064137 | author_follow_tracking | **MISSING** | no tracked file |
| 20261022065558 | character_nsfw_workplace_warning | **MISSING** | no tracked file |
| 20261022072751 | grant_public_profile_columns_select | **MISSING** | no tracked file |
| 20261022072918 | secure_public_profiles_and_restore_profile_reads | **MISSING** | no tracked file |
| 20261022073159 | limit_public_profiles_view_to_select_only | **MISSING** | no tracked file |
| 20261022094147 | delete_chat_group_with_related_data | **MISSING** | no tracked file |
| 20261022094349 | delete_chat_session_content | **MISSING** | no tracked file |
| 20261022173642 | secure_character_turn_count_visibility | `supabase/migrations/20261022173642_secure_character_turn_count_visibility.sql` | matched |
| 20261022175412 | sync_group_character_snapshots_on_delete_and_update | `supabase/migrations/20261022175412_sync_group_character_snapshots_on_delete_and_update.sql` | matched |
| 20261022180019 | backfill_deleted_character_chat_snapshots | **MISSING** | no tracked file |
| 20261022180206 | secure_public_profiles_invoker_and_column_grants | **MISSING** | no tracked file |
| 20261022182628 | save_my_profile_owner_checked_rpc | **MISSING** | no tracked file |
| 20261022185425 | exclude_deleted_group_messages_from_turn_counts | **MISSING** | no tracked file |
| 20261022233024 | fix_group_memory_photo_storage_read_policy | `supabase/migrations/20261022233024_fix_group_memory_photo_storage_read_policy.sql` | matched |
| 20261023012000 | group_chat_billing_per_character | `supabase/migrations/20261023012000_group_chat_billing_per_character.sql` | matched |
| 20261023035710 | group_chat_billing_per_character | **MISSING** | no tracked file |
| 20261023092154 | restrict_public_default_privileges | **MISSING** | no tracked file |
| 20261023092523 | restrict_postgres_public_sequence_defaults | **MISSING** | no tracked file |
| 20261023092715 | revoke_anon_public_sequence_access | **MISSING** | no tracked file |
| 20261023095003 | exclude_deleted_chat_from_character_turn_counts | `supabase/migrations/20261023095003_exclude_deleted_chat_from_character_turn_counts.sql` | matched |
| 20261023104741 | protect_whisper_reply_direct_select | **MISSING** | no tracked file |
| 20261023111142 | guard_whisper_thread_cycles | **MISSING** | no tracked file |
| 20261023112911 | allow_anon_rls_whisper_helper | **MISSING** | no tracked file |
| 20261023122555 | fix_safe_comment_rpc_whisper_ancestry | **MISSING** | no tracked file |
| 20261024002459 | guard_memory_photo_delete_during_pending_account_deletion | **MISSING** | no tracked file |
| 20261024050120 | revoke_direct_profile_writes | **MISSING** | no tracked file |
| 20261024061142 | fix_whisper_reply_ancestry_authorization | **MISSING** | no tracked file |
| 20261024073819 | character_nsfw_terms_and_age_gate | **MISSING** | no tracked file |
| 20261024073923 | character_avatar_video_storage | **MISSING** | no tracked file |
| 20261024074821 | fix_character_nsfw_rls_and_video_read | **MISSING** | no tracked file |
| 20261024074938 | enforce_character_video_owner_path | **MISSING** | no tracked file |
| 20261024075220 | move_adult_check_to_private_schema | **MISSING** | no tracked file |
| 20261024083626 | enforce_nsfw_age_gate_for_character_reads | **MISSING** | no tracked file |
| 20261028034854 | encounter_mode_core_schema | **MISSING** | no tracked file |
| 20261028055543 | atomic_encounter_schedule_sync | **MISSING** | no tracked file |
| 20261028072202 | trusted_encounter_interaction | **MISSING** | no tracked file |
| 20261028072315 | safe_encounter_schedule_resolver | **MISSING** | no tracked file |
| 20261028075129 | trusted_chat_mode_marker | **MISSING** | no tracked file |
| 20261028080237 | enforce_trusted_chat_mode | **MISSING** | no tracked file |
| 20261028080945 | encounter_session_access_check | **MISSING** | no tracked file |
| 20261028103534 | idempotent_encounter_turn_interaction | **MISSING** | no tracked file |
| 20261028120032 | prevent_duplicate_chat_message_charges | **MISSING** | no tracked file |
| 20261029011336 | allow_all_eligible_public_encounter_schedules | **MISSING** | no tracked file |
| 20261029034207 | allow_all_eligible_encounter_sessions | `supabase/migrations/20261029034207_allow_all_eligible_encounter_sessions.sql` | matched |
| 20261029224513 | validate_settled_encounter_interaction | **MISSING** | no tracked file |
| 20261030213037 | affinity_system_foundation | **MISSING** | no tracked file |
| 20261030215321 | encounter_turn_evidence_writer | **MISSING** | no tracked file |
| 20261030222510 | encounter_scene_settlement | **MISSING** | no tracked file |
| 20261030222553 | block_expired_encounter_turns | **MISSING** | no tracked file |
| 20261030224826 | atomic_encounter_turn_reservation | **MISSING** | no tracked file |
| 20261030224911 | allow_preexpiry_reserved_turn_completion | **MISSING** | no tracked file |
| 20261030230919 | encounter_session_pause_resume | **MISSING** | no tracked file |
| 20261031010419 | allow_preexpiry_encounter_retry | **MISSING** | no tracked file |
| 20261031010515 | fix_encounter_retry_charge_lookup | **MISSING** | no tracked file |
| 20261031010719 | restrict_encounter_retry_lifecycle_states | **MISSING** | no tracked file |
| 20261031011247 | validate_story_batch_turn_sources | **MISSING** | no tracked file |
| 20261031011426 | encounter_evaluation_dispatch_queue | **MISSING** | no tracked file |
| 20261031011509 | bound_encounter_evaluation_retries | **MISSING** | no tracked file |
| 20261031011944 | latest_settled_encounter_for_story | **MISSING** | no tracked file |
| 20261031012300 | story_relationship_state_read_rpc | **MISSING** | no tracked file |
| 20261031021650 | city_character_affinity_display | **MISSING** | no tracked file |
| 20261031033312 | character_illustration_storage | **MISSING** | no tracked file |
| 20261031033429 | fix_character_illustration_storage_policy_paths | **MISSING** | no tracked file |
| 20261031055744 | character_illustration_display_names | **MISSING** | no tracked file |
| 20261031110122 | author_encounter_schedule_descriptions | **MISSING** | no tracked file |
| 20261031110247 | index_author_encounter_schedule_descriptions | **MISSING** | no tracked file |
| 20261031131524 | character_illustration_cleanup_queue | **MISSING** | no tracked file |
| 20261031131654 | fix_character_illustration_cleanup_path_check | **MISSING** | no tracked file |
| 20261101052444 | chat_deletion_queue_foundation | `supabase/migrations/20261101052444_chat_deletion_queue_foundation.sql` | matched |
| 20261101052951 | chat_soft_delete_lifecycle | `supabase/migrations/20261101052951_chat_soft_delete_lifecycle.sql` | matched |
| 20261101053732 | chat_writer_parent_first_guards | `supabase/migrations/20261101053732_chat_writer_parent_first_guards.sql` | matched |
| 20261101054027 | encounter_chat_deletion_gates | `supabase/migrations/20261101054027_encounter_chat_deletion_gates.sql` | matched |
| 20261101054353 | chat_memory_storage_lifecycle_policies | `supabase/migrations/20261101054353_chat_memory_storage_lifecycle_policies.sql` | matched |
| 20261101054423 | fix_chat_memory_storage_insert_path | `supabase/migrations/20261101054423_fix_chat_memory_storage_insert_path.sql` | matched |
| 20261101055617 | chat_deletion_purge_worker_rpc | `supabase/migrations/20261101055617_chat_deletion_purge_worker_rpc.sql` | matched |
| 20261101055901 | fix_group_turn_content_purge_marker | `supabase/migrations/20261101055901_fix_group_turn_content_purge_marker.sql` | matched |
| 20261101060225 | preserve_wallet_character_label_after_chat_purge | `supabase/migrations/20261101060225_preserve_wallet_character_label_after_chat_purge.sql` | matched |
| 20261101101343 | enable_pg_net_for_chat_deletion_worker | `supabase/migrations/20261101101343_enable_pg_net_for_chat_deletion_worker.sql` | matched |
| 20261101110211 | account_deletion_character_video_storage_gates | **MISSING** | no tracked file |

## Repository timestamp files not present in remote ledger

| Repository file | Git blob SHA |
|---|---|
| `supabase/migrations/20261015150500_guard_pending_deletion_group_activity.sql` | `8c10776e9a52b33f0d06a620df77372c77ff76fd` |
| `supabase/migrations/20261015151500_freeze_group_access_pending_deletion.sql` | `38a3575377b97699107e9851ed53b5499fe1648a` |
| `supabase/migrations/20261015151500_optimize_rls_auth_initplan_policies.sql` | `20b9b381732668a444b7037ff791376fb2d5b64a` |
| `supabase/migrations/20261015153500_harden_character_soft_delete_helper_rpc.sql` | `3093fa37286dfcba2523adedc831f85dd841ca17` |
| `supabase/migrations/20261015163000_limit_deletion_archive_execution.sql` | `2e0d7e1e6987cd3809798f5a83b9a68cc27f2edb` |
| `supabase/migrations/20261015170000_freeze_pending_account_character_writes.sql` | `c9fa9f3e4d8699bb117cda550c3e1ce186aa4fec` |
| `supabase/migrations/20261015180000_restore_account_deletion_grace_period.sql` | `0adac5218ce79c11177a663ef964d1439ea7d1b8` |
| `supabase/migrations/20261015190000_restore_test_account_deletion_five_minute_grace_period.sql` | `da23920d444d0f96c04963341923e4bdf78a64a0` |
| `supabase/migrations/20261016003000_guard_chat_turn_assistant_upsert.sql` | `2b9173aff70f105cf9957f83632471b468a7808c` |
| `supabase/migrations/20261017013000_validate_group_name_length_constraint.sql` | `89a0ebe37f638996b44e0f0191e47ca947d04d4c` |
| `supabase/migrations/20261018150500_test_grant_diamonds_200_once.sql` | `53c0a96f7fb0905b55a75fbae0373f6c31e3ed67` |
| `supabase/migrations/20261018162000_daily_checkin_silver_reward_cycle.sql` | `75705902d0c6a2d564e8b0ca6780c096b0dec4f4` |
| `supabase/migrations/20261019100000_add_chat_group_pinned.sql` | `047bff73d11ca4daee876707616225ac2bf3ce35` |
| `supabase/migrations/20261020120000_restrict_test_diamond_grant_rpc.sql` | `36a45241581a25f8d6bf7f7fdc4fe9b9c896336e` |
| `supabase/migrations/20261020120000_unified_memory_album.sql` | `d03b1cdb9818b3b0c506c26b9b94179a35faf65a` |
| `supabase/migrations/20261020123000_memory_album_fk_indexes.sql` | `9e7946a1b7c4af005f00933024b2794cd5809e66` |
| `supabase/migrations/20261020140000_memory_album_owner_updates.sql` | `f1372c9050946a5a0cd54f560e19cab66c98bc84` |
| `supabase/migrations/20261020150000_soft_delete_memory_photo_rpc.sql` | `4a1f1979d92dad42847c3ba3548577c99f26166a` |
| `supabase/migrations/20261021050000_group_message_soft_delete.sql` | `67c9c8ab851c8c929fb75e2d220035e0a23d7b7b` |
| `supabase/migrations/20261021060000_allow_group_message_soft_delete.sql` | `980d6169afbb2bbff34785f87b7120955e5145ba` |
| `supabase/migrations/20261021090000_public_character_turn_count.sql` | `9ca222e68f717825f474cfba3eb03cd3fc8bc1b5` |
| `supabase/migrations/20261021100000_add_character_phone_settings.sql` | `ccc7742b6d814c4415f6c6378c085c0163cfc259` |
| `supabase/migrations/20261021110000_include_group_turns_in_character_counts.sql` | `dca2b63ca994aa7ab20c1ec13466e12a4e8c4538` |
| `supabase/migrations/20261022130000_create_group_sweet_diary_cloud_sync.sql` | `6535f60ad0b9a054b65bb6a6a9b76a956d74c1a6` |
| `supabase/migrations/20261022130100_index_group_sweet_diary_owner.sql` | `c3d1a179a702da3e647781e0b6b9fcd03a7584d6` |
| `supabase/migrations/20261023013000_backfill_deleted_character_chat_snapshots.sql` | `801f3261b4424649d9231c91c15f92a7d031c0a7` |
| `supabase/migrations/20261023014500_secure_public_profiles_invoker_and_column_grants.sql` | `f2d7bcac094e06a9a5139c73dc6f6d0e99b56f79` |
| `supabase/migrations/20261023030000_save_my_profile_owner_checked_rpc.sql` | `1600a154525beb31e98c7e92b9162a9b59860b96` |
| `supabase/migrations/20261023040000_restrict_public_default_privileges.sql` | `c7341ea4d2ee63ba15a59461719677fdc8a8b1c2` |
| `supabase/migrations/20261023120000_exclude_deleted_group_messages_from_turn_counts.sql` | `e490505d7020760c2762aea59443bcd7cb5f0c4b` |
| `supabase/migrations/20261023120000_protect_whisper_reply_direct_select.sql` | `c408d40fdfd9b7beb09febf4764945c2a0c39d24` |
| `supabase/migrations/20261023123000_fix_safe_comment_rpc_whisper_ancestry.sql` | `d54899c0c2bc90893a123cd8cca0450d351de03a` |
| `supabase/migrations/20261024090000_fix_whisper_reply_ancestry_authorization.sql` | `1120b56c4634342ac0e2e5812eb0a124d5873763` |
| `supabase/migrations/20261024153000_character_nsfw_terms_and_age_gate.sql` | `14ad87be9ea3e7a49f12e79e8d78c71d3b22c0cd` |
| `supabase/migrations/20261024154000_character_avatar_video_storage.sql` | `4c7a7f6ee549bf1b3ea3b1634befd6dd7fe32250` |
| `supabase/migrations/20261024160000_fix_character_nsfw_rls_and_video_read.sql` | `2d857d730c669e26baee2191ed6a131ac6d2c3d9` |
| `supabase/migrations/20261024161000_enforce_character_video_owner_path.sql` | `73ec3eee70b491fb128c1a12b567beb5d67d3b46` |
| `supabase/migrations/20261024162000_move_adult_check_to_private_schema.sql` | `7949996ff6b4c0dac2dd0daed9beeeb56f30512f` |
| `supabase/migrations/20261024170000_enforce_nsfw_age_gate_for_character_reads.sql` | `e5949fdfa8d97fbd7aa4d7408f0555bec6606d8c` |
| `supabase/migrations/20261024170000_fix_owner_nsfw_character_read.sql` | `b9bfd1a058285105c7e14ccad205244cc06bce66` |
| `supabase/migrations/20261024180000_fix_nsfw_public_rpc_age_gate.sql` | `e75adf30d5fda0959747a963fa575617ebdca334` |
| `supabase/migrations/20261028120000_encounter_mode_core_schema.sql` | `826b19e0662fa27c0240264ba499def84ad11845` |
| `supabase/migrations/20261028143000_atomic_encounter_schedule_sync.sql` | `0f7ca61e219c81fc13a2cbfdce132380cff4ce25` |
| `supabase/migrations/20261028160000_trusted_encounter_interaction.sql` | `c1b3b3c1a3595507406eeac809558c36ead6be6c` |
| `supabase/migrations/20261028163000_safe_encounter_schedule_resolver.sql` | `979c3101aa41dcb0950d4db141c2d31c5fc9e88c` |
| `supabase/migrations/20261028170000_trusted_chat_mode_marker.sql` | `a1330c11f3e8a5c84e0d37eb3903430e458926b7` |
| `supabase/migrations/20261028173000_enforce_trusted_chat_mode.sql` | `d707d11e684ba842969395070fe67091bf9613cc` |
| `supabase/migrations/20261028180000_encounter_session_access_check.sql` | `8cd65d7b99032d8db1e987e03e35431766329bb9` |
| `supabase/migrations/20261028190000_idempotent_encounter_turn_interaction.sql` | `6cab65e9561d9d1bc8155d77d0d51f8068ca81fb` |
| `supabase/migrations/20261028193000_prevent_duplicate_chat_message_charges.sql` | `ea0769c40d57a66447c19daf08e7798fa0acdd9d` |
| `supabase/migrations/20261029120000_allow_all_eligible_public_encounter_schedules.sql` | `fd1f5aa1bedd67e9081e2548e5312d541d0dad8f` |
| `supabase/migrations/20261029210000_validate_settled_encounter_interaction.sql` | `202be5efcd61abc4696dac9efdfdc5ee0e697479` |
| `supabase/migrations/20261030120000_affinity_system_foundation.sql` | `2825fee07560ac28a137aaba0affe56c35f418f6` |
| `supabase/migrations/20261031100000_character_illustration_storage.sql` | `c5e563c8d04c42077075c79f197bce509979b9de` |
| `supabase/migrations/20261031103000_fix_character_illustration_storage_policy_paths.sql` | `0649bb1fc0fc24f86264285c14276183d50d0b97` |
| `supabase/migrations/20261031120000_author_encounter_schedule_descriptions.sql` | `677adae620b28f5cbd7f545287d8b691bc898252` |
| `supabase/migrations/20261031120000_character_illustration_display_names.sql` | `6431c36f3a1988af63e72552fe917f60494be40a` |
| `supabase/migrations/20261031120000_encounter_turn_evidence_writer.sql` | `97b94e248cbe78789263a59cd34fd6f39bf108a8` |
| `supabase/migrations/20261031120500_index_author_encounter_schedule_descriptions.sql` | `d6776a376497e421c3810e14067015436ea0da16` |
| `supabase/migrations/20261031150000_encounter_scene_settlement.sql` | `56d4042bb899df2a98043048a20bd79873553683` |
| `supabase/migrations/20261031160000_block_expired_encounter_turns.sql` | `049fe6a5876ef2788c835997da14655742d37e16` |
| `supabase/migrations/20261031170000_atomic_encounter_turn_reservation.sql` | `390a008fee244ae0451cd7d4c7c327f95e8ee616` |
| `supabase/migrations/20261031180000_allow_preexpiry_reserved_turn_completion.sql` | `b523a16bcc748ae305b126264001ebac73b2fdfc` |
| `supabase/migrations/20261031190000_encounter_session_pause_resume.sql` | `0c9284ef5e3a073a01d1db1a0b3abcc39aad808b` |
| `supabase/migrations/20261031200000_allow_preexpiry_encounter_retry.sql` | `cfee4f7d5a19be2a4ee31170cb9c5ddae3a459b4` |
| `supabase/migrations/20261031210000_fix_encounter_retry_charge_lookup.sql` | `cfee4f7d5a19be2a4ee31170cb9c5ddae3a459b4` |
| `supabase/migrations/20261031211200_character_illustration_cleanup_queue.sql` | `d7995154f2ad8fcdf578b2401ecb8b853485e615` |
| `supabase/migrations/20261031212000_fix_character_illustration_cleanup_path_check.sql` | `c28f17bbbeb9d45aa7f6ac9e1f06996ac68e1571` |
| `supabase/migrations/20261031220000_restrict_encounter_retry_lifecycle_states.sql` | `d8757bd110d7ca304f1283189c3babbe83ff1caf` |
| `supabase/migrations/20261031230000_validate_story_batch_turn_sources.sql` | `92367098fed8e114cd53a4d02e8834de76cff68c` |
| `supabase/migrations/20261031240000_encounter_evaluation_dispatch_queue.sql` | `3aa8580d43192be3cf3029199d9ba3ca94e4294c` |
| `supabase/migrations/20261031250000_bound_encounter_evaluation_retries.sql` | `453219f876494d5e497bf467f674a31abe530bdd` |
| `supabase/migrations/20261031260000_latest_settled_encounter_for_story.sql` | `f5fe8492b63cb18a125a9ded598eac143102cb92` |
| `supabase/migrations/20261031270000_story_relationship_state_read_rpc.sql` | `8f976d68bf92977f024f76e92acd1c29e5f8627a` |
| `supabase/migrations/20261031280000_city_character_affinity_display.sql` | `beffc0529da91711880612f1584c6ca53e682d87` |

## Legacy files without 14-digit version prefix

| Repository file | Git blob SHA |
|---|---|
| `supabase/migrations/20261015_character_soft_delete.sql` | `9fedc459098f9bd1fd9ac9842908b79b99c1faaf` |
| `supabase/migrations/20261015_chat_session_character_access.sql` | `ab218c3820b3d4ba481f39e6c2181d228bf05ff0` |
| `supabase/migrations/20261015_chat_turn_ledger_idempotency.sql` | `fc43672d9d511632d6c3db53c4ce7627dde547b4` |
| `supabase/migrations/20261015_chat_turn_transaction_functions.sql` | `ebf0dc0e7959c8d63ecfe681cdc99e0b3abac0f6` |
| `supabase/migrations/20261015_fix_reserve_chat_turn_conflict_target.sql` | `ed2f671457801fc08fe6a404ed4234f3bdf20c0a` |

## Duplicate timestamp collisions in repository

- `20261015151500`: `supabase/migrations/20261015151500_freeze_group_access_pending_deletion.sql`, `supabase/migrations/20261015151500_optimize_rls_auth_initplan_policies.sql`
- `20261020120000`: `supabase/migrations/20261020120000_restrict_test_diamond_grant_rpc.sql`, `supabase/migrations/20261020120000_unified_memory_album.sql`
- `20261023120000`: `supabase/migrations/20261023120000_exclude_deleted_group_messages_from_turn_counts.sql`, `supabase/migrations/20261023120000_protect_whisper_reply_direct_select.sql`
- `20261024170000`: `supabase/migrations/20261024170000_enforce_nsfw_age_gate_for_character_reads.sql`, `supabase/migrations/20261024170000_fix_owner_nsfw_character_read.sql`
- `20261031120000`: `supabase/migrations/20261031120000_author_encounter_schedule_descriptions.sql`, `supabase/migrations/20261031120000_character_illustration_display_names.sql`, `supabase/migrations/20261031120000_encounter_turn_evidence_writer.sql`

## Interpretation / rules

- A matching version number is not by itself proof that the SQL contents are identical to the SQL that was applied remotely. Compare file content, commit history, and available authoritative migration source before treating a file as recovered.
- A remote ledger entry without a tracked file means the source SQL is not currently represented by the same versioned path in this branch. It may have been renamed, omitted, applied manually, or otherwise drifted; provenance must be investigated.
- A repository-only version may be unapplied, locally renamed, or a historical alternate. Do not apply it to hosted test project until reconciled.
- Duplicate local timestamps make clean replay nondeterministic/invalid and must be resolved with a deliberate new baseline/reconciliation strategy, not by silently renaming applied versions.
- Do not change hosted `supabase_migrations.schema_migrations`, run hosted `db reset`, or use `db push` to bypass these mismatches.
- The project has no real users and is test-only, so a disposable-local consolidated baseline is an acceptable direction to evaluate. It must be clearly labeled as a reconstruction, not falsely described as original migration provenance.
