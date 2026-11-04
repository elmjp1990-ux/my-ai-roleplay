# Character history FK classification — 2026-11-02

Scope: read-only PostgreSQL catalog review of the connected test project. This is a classification of the current schema, not a historical migration or a live database mutation.

## Rule

A never-published, never-used private draft may be hard-deleted only if no player-use history exists. Any existing single chat, group participation/message/world reference, legacy conversation, encounter record, relationship record, or comment forces soft-delete/archive. Creator-authored draft configuration and media metadata may cascade with a safe draft hard-delete.

## Current inbound foreign keys to public.characters

The live catalog returned these 18 inbound references:

| Referencing table | FK delete action | Classification | Guard behavior |
|---|---|---|---|
| character_comments | CASCADE | Player-visible interaction/history | Blocks hard-delete |
| character_illustrations | CASCADE | Creator-authored asset metadata | Does not block; queues exact Storage paths before hard-delete |
| character_private_info | CASCADE | Creator-authored private configuration | Does not block for never-used draft |
| character_schedule_descriptions | CASCADE | Creator-authored schedule configuration | Does not block for never-used draft |
| character_schedules | CASCADE | Creator-authored schedule configuration | Does not block for never-used draft |
| character_stories | CASCADE | Creator-authored story template | Blocks only when a legacy conversation references the story |
| chat_group_members | SET NULL | Existing group participation | Blocks hard-delete |
| chat_group_messages | SET NULL | Existing group transcript | Blocks hard-delete |
| chat_groups.world_character_id | SET NULL | Existing group world/scene reference | Blocks hard-delete |
| chat_sessions | SET NULL | Existing single/story session, including tombstones | Blocks hard-delete |
| encounter_character_state | CASCADE | Encounter relationship state | Blocks hard-delete |
| encounter_diary | CASCADE | Encounter memory/diary | Blocks hard-delete |
| encounter_session_evaluation_jobs | SET NULL | Encounter processing/history evidence | Blocks hard-delete |
| encounter_session_lifecycle | SET NULL | Encounter lifecycle history | Blocks hard-delete |
| encounter_session_turns | SET NULL | Encounter transcript/turn history | Blocks hard-delete |
| encounter_turn_interaction_receipts | CASCADE | Encounter turn evidence | Blocks hard-delete |
| story_relationship_batches | SET NULL | Story relationship history | Blocks hard-delete |
| story_relationship_states | SET NULL | Story relationship state | Blocks hard-delete |

## Non-FK references

A second read-only information_schema.columns scan for character_id, world_character_id, and speaker_character_id returned the same application table set; no additional public tables with those columns were found.

The current private.character_has_history(uuid) draft explicitly checks every player-history source in the table above, plus chat_deletion_character_history (the durable snapshot source). Legacy conversations are joined through character_stories, so an unused story template can be deleted but a story with an existing conversation cannot.

## Regression coverage

The static guard now asserts that every history-bearing table appears in the history guard and that creator-authored metadata tables are not accidentally treated as player history. It also checks the legacy conversation-to-story join.

## Limitations

This is a live catalog snapshot, not a PostgreSQL execution test. It does not prove there are no references encoded in JSON/text columns or external systems; source searches and application-specific review remain necessary. The draft SQL remains unexecuted. No hosted DDL/DML, Storage mutation, migration, deployment, or Cron change was made.
