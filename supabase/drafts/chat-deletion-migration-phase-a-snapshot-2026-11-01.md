# Migration Phase A — read-only live schema snapshot (initial)

Date: 2026-11-01
Project: `ouyewoagbmtqehbofrje` (test only)
Repository: `elmjp1990-ux/my-ai-roleplay`
PR: #200, branch `security/chat-deletion-lifecycle-reconciliation`
Mode: read-only catalog queries only. No DDL/DML, no secrets, no user content.

## Snapshot counts

| Catalog area | Count |
|---|---:|
| Non-system tables | 95 |
| Non-system views | 4 |
| Non-system functions | 199 |
| Non-internal triggers | 33 |
| RLS policies | 108 |
| Table constraints | 932 |
| Indexes | 285 |
| Installed extensions | 7 |
| Active cron jobs | 1 |

These are initial inventory counts, not a full schema dump or proof that all objects are replayable. A full snapshot still needs object definitions, ownership, grants, RLS policy expressions, indexes/constraints, triggers, and dependencies.

## Non-system schemas observed

`auth`, `cron`, `extensions`, `graphql`, `graphql_public`, `net`, `private`, `public`, `realtime`, `storage`, `supabase_migrations`, `vault`.

## Extensions observed

| Extension | Version | Schema |
|---|---:|---|
| pg_cron | 1.6.4 | pg_catalog |
| pg_net | 0.20.4 | extensions |
| pg_stat_statements | 1.11 | extensions |
| pgcrypto | 1.3 | extensions |
| plpgsql | 1.0 | pg_catalog |
| supabase_vault | 0.3.1 | vault |
| uuid-ossp | 1.1 | extensions |

## Storage buckets observed

All three buckets are private. The chat deletion worker is intentionally scoped only to `personax-memory-photos`.

| Bucket | Public | Max file size | Allowed MIME types |
|---|---:|---:|---|
| personax-memory-photos | false | 10 MiB | image/jpeg, image/png, image/webp |
| character-illustrations | false | 10 MiB | image/jpeg, image/png, image/webp |
| character-avatar-videos | false | 15 MiB | video/mp4, video/webm, video/quicktime |

Character illustration/video buckets must remain outside the chat deletion sweep.

## Cron observed

Exactly one active job:
- `poyozz-encounter-evaluation-dispatch`
- Schedule: every minute (`* * * * *`)
- Command: `SELECT public.enqueue_due_encounter_evaluations(50);`

No chat-deletion cron or account-deletion cron was observed.

## Relevant live function definitions read back

The following definitions were read from `pg_get_functiondef` for provenance comparison:
- `public.delete_chat_session_content(uuid)`
- `public.delete_chat_group_with_related_data(uuid)`
- `public.prepare_account_deletion(uuid)`
- `public.finalize_account_deletion(uuid)`
- `public.mark_chat_storage_deletion_job(uuid, boolean, text)`

The two historical chat deletion functions currently present in the live database implement the PR #200 shared 30-day lifecycle: lock and ownership-check the parent, insert/reuse one `chat_deletion_jobs` row with `purge_after = deleted_at + 30 days`, enqueue only chat-memory photo object paths in `personax-memory-photos`, then set the parent `deleted_at`. They no longer immediately clear chat content. This is useful live-object provenance, but it does not recover the missing historical SQL source files or establish a clean replay chain.

`prepare_account_deletion` currently archives AI generation, wallet transactions, chat charges and turn events before deleting account-owned relational source rows; its broader account Storage sweep remains a separate unimplemented requirement. `finalize_account_deletion` marks completion only after the Auth user no longer exists.

The queue functions inspected are SECURITY DEFINER, owned by postgres, and configured with an empty search_path. Do not change their privileges or ownership as part of inventory work without separate security review.

## Migration history cross-check

- Supabase migration list currently returns 151 live history entries.
- Existing repository inventory baseline: 96 migration SQL files before PR #200.
- PR #200 contributes 10 migration files; current PR branch inventory is therefore 106 expected SQL migration files.
- Existing mismatch report remains: 67 shared names with timestamp-prefix mismatch, 57 live-only, 14 repo-only, duplicate repository prefixes, five legacy files without unique 14-digit versions, and two historical chat deletion SQL sources missing from GitHub history.
- The live migration history includes all ten PR #200 migration versions (the last is `20261101110211_account_deletion_character_video_storage_gates` in the observed list); this inventory does not authorize replay or history repair.

## What this snapshot does not contain

- No row data, user content, Vault secret values, JWTs, API keys, or Storage object bytes were read.
- No complete definitions for all 199 functions, 108 policies, 33 triggers, 932 constraints, 285 indexes, or 4 views were exported yet.
- No schema diff against a clean local database has been performed.
- No local replay has been attempted; local Docker availability has not been assumed.
- No migration was applied, reverted, repaired, reset, or pushed.

## Next Phase A/B actions

1. Export object definitions in bounded batches, preserving owner, security-definer status, search_path, grants and dependencies.
2. Capture table columns/defaults, constraints/FKs, indexes, trigger definitions, policies, views, Storage policies and cron definitions.
3. Build a source provenance matrix for the 57 live-only, 14 repo-only, 67 timestamp-mismatch cases, duplicate prefixes and the two missing chat deletion source files.
4. Keep all hosted operations read-only. If a local replay is later possible, use a separate disposable local checkout/database only.
