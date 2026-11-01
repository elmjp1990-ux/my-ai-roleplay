# `public.characters` baseline provenance investigation — 2026-11-02

Repository: `elmjp1990-ux/my-ai-roleplay`  
Working branch: `security/chat-deletion-lifecycle-reconciliation`  
Supabase test project: `ouyewoagbmtqehbofrje`  
Scope: read-only schema and migration-history inspection; documentation only.

## Confirmed live test database state

Read-only `list_tables` and catalog inspection confirms:

- `public.characters` exists in the connected test project.
- It currently contains 11 rows. This count does not establish whether those rows are the original sample characters; no row names or content were inspected.
- It is RLS-enabled.
- Current columns include `id`, `author_id`, `name`, `title`, `gender`, `age`, `avatar_url`, `visibility`, `review_status`, `created_at`, `intro`, `race`, `style`, `tags`, `first_published_at`, `latest_eligible`, `rights_confirmed`, `deleted_at`, `deletion_reason`, `phone_settings`, `nsfw_workplace_warning`, `is_nsfw`, `avatar_video_path`, and `personality_profile`.
- Numerous live tables have foreign keys referencing `public.characters(id)`, including chat, group, story, illustration, schedule and encounter tables. It is a core application table, not a sample-data table.

## Confirmed migration-history gap

The live `supabase_migrations.schema_migrations` history begins at version `20261015065943` (`isolate_character_private_info`).

That first recorded migration creates `public.character_private_info` with a foreign key to `public.characters(id)`, and copies rows from `public.characters`. It does not create `public.characters` or `public.profiles`.

The next recorded migrations also assume existing base tables. The repository's `supabase/migrations` directory has no migration that creates the original `public.characters` table. A read-only scan of all recorded migration statements also found no `CREATE TABLE public.profiles`; the baseline gap therefore appears to include both foundational tables, not just `characters`. Its earliest timestamped group schema migration is `20261015141259_group_chat_core_schema`, which also references `public.characters`.

Repository file `supabase/migrations/20261015_character_soft_delete.sql` is an ALTER/soft-delete migration; it adds `deleted_at` and `deletion_reason` and creates functions/policies. It is not the base table creation.

Therefore the local clean replay error is consistent with a missing pre-existing baseline: the live database had base schema created before the first tracked migration, likely through an earlier manual SQL / Dashboard operation or an untracked initial setup script. The exact source is not yet recovered.

## User-provided history

The user recalls creating a batch of public sample characters before using ChatGPT for coding, then later asking for those sample character records to be deleted.

That history may explain deletion of example rows, but it does not imply the `public.characters` relation was dropped. Current live schema confirms the relation still exists. Do not conflate row deletion with table deletion.

## Safety decisions

- Do NOT drop, recreate, truncate, or reset `public.characters`.
- Do NOT treat the current 11 rows as proof of original sample data or inspect their contents without a specific need.
- Do NOT create a guessed baseline migration from current live state and label it as the original history.
- Do NOT alter hosted migration history or run `db reset` / `db push` to bypass this issue.
- Do NOT replay historical migrations against the connected test project.
- PR #200 remains Draft/unmerged; no hosted DDL/DML was executed during this investigation.

## Next recovery steps

1. Search the earliest project setup history, old SQL Editor snippets/exports, and repository history before `20261015065943` for the original `profiles` and `characters` CREATE TABLE statements.
2. Compare recovered original base schema against live catalog metadata: columns/defaults, PK/FK/check constraints, indexes, RLS policies, triggers, grants, sequences and dependent objects.
3. If original source cannot be recovered, design a separately reviewed, clearly labeled **baseline reconstruction for disposable local test replay only**, generated from catalog evidence and validated independently. Do not silently backdate it or claim it is the original migration.
4. Only after the baseline is reproducible should PR #200 migration replay and transactional deletion/snapshot tests resume.

## Evidence

- Live migration `20261015065943 / isolate_character_private_info` begins by creating `character_private_info` referencing `characters`; it does not create `characters`.
- Live test database table listing confirms `public.characters` and its current columns/FK dependencies.
- Repository file `supabase/migrations/20261015_character_soft_delete.sql` alters an already-existing table.
