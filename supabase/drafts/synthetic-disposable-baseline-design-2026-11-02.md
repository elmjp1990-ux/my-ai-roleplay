# Synthetic disposable baseline design — 2026-11-02

Repository: `elmjp1990-ux/my-ai-roleplay`
Branch: `security/chat-deletion-lifecycle-reconciliation`
Supabase source: test project `ouyewoagbmtqehbofrje`
Capture method: read-only PostgreSQL catalog queries and Supabase schema metadata. No application table rows were queried or exported.

## Decision: separate two different test purposes

The term 'baseline' had been overloaded. The repository needs two independent fixtures; they must not be conflated:

1. **Current-state disposable schema fixture** — a schema-only reconstruction of the live test project's current application schema. It exists to replay PR #200 draft SQL against a disposable PostgreSQL instance and run deletion/security tests. It is not a migration-history baseline.
2. **Pre-ledger migration foundation** — the `profiles` and `characters` definitions that existed before the first recorded migration (`20261015065943`). This is required only for a true clean-room replay of the historical migration chain. Its original source remains unrecovered, and the remote ledger/repository source drift remains unresolved.

Do not place either fixture in `supabase/migrations/`. Store it under `supabase/drafts/` or a clearly named `supabase/tests/fixtures/` directory, and label it disposable-only.

## Live schema fingerprint (read-only, 2026-11-02)

| Object | Count / state |
|---|---:|
| `public` tables | 47 |
| `public` views | 1 (`public_profiles`) |
| `public` sequences | 2 |
| `public` indexes | 140 |
| `public` constraints | 288 |
| `public` RLS policies | 95 |
| `public` triggers | 23 distinct triggers (38 event rows) |
| `public` + `private` functions | 77 (73 public, 4 private) |
| `public` composite types | 48 (PostgreSQL table row types; no public enum/domain types observed) |
| `public` RLS enabled | 47 / 47 tables |
| `public` FORCE RLS | 0 tables |

Installed extensions observed: `pg_cron 1.6.4`, `pg_net 0.20.4`, `pg_stat_statements 1.11`, `pgcrypto 1.3`, `plpgsql 1.0`, `supabase_vault 0.3.1`, `uuid-ossp 1.1`.

Supabase-managed `auth` and `storage` schemas are platform bootstrap dependencies. A local fixture should use the local Supabase stack's own auth/storage schema rather than copying platform-owned data or attempting to recreate those schemas manually.

## Why current state cannot be used as the pre-ledger foundation

The first remote migration is `20261015065943 / isolate_character_private_info`; it assumes both `public.characters` and `public.profiles` already exist. It creates `character_private_info`, migrates private information, and drops `characters.private_info`; it does not create either foundation table.

Current tracked migrations prove that several live columns are later migration deltas, not pre-ledger foundation fields:

| Later migration | Existing change to `public.characters` |
|---|---|
| `20261015_character_soft_delete.sql` | adds `deleted_at`, `deletion_reason` |
| `20261021100000_add_character_phone_settings.sql` | adds `phone_settings` |
| `20261024153000_character_nsfw_terms_and_age_gate.sql` | adds `is_nsfw` |
| `20261024154000_character_avatar_video_storage.sql` | adds `avatar_video_path` |

Therefore snapshotting today's `characters` and then replaying the historical chain would cause duplicate-column / already-existing-object conflicts and would produce a false clean-room result. The same concern applies to other later schema deltas and policies.

## Current-state fixture requirements

The current-state fixture must be schema-only and include, in dependency order:

1. Supabase local platform bootstrap (roles, `auth.users`, `storage.objects`, Storage helpers, and supported extensions).
2. `public` and `private` application schemas; all 47 application tables; the two sequences; primary/unique/check/foreign-key constraints; and all 140 indexes.
3. All 77 application functions with exact signatures, language, volatility, SECURITY DEFINER/search_path settings, ownership and ACLs.
4. All 95 RLS policies, table RLS flags, 23 triggers and their trigger functions, the `public_profiles` view, comments, grants and default privileges.
5. Empty application tables. No users, profiles, characters, chats, wallet rows, or Storage objects are copied.

Do not claim the fixture is complete until the generated SQL is replayed in a disposable PostgreSQL/Supabase instance and its object fingerprint matches the source fingerprint above.

## Migration replay remains a separate gate

The repository/remote migration manifest records source/version drift and missing remote migration names. A full historical replay must wait for exact source recovery or a separately reviewed pre-ledger reconstruction. The current-state fixture must not be used to bypass that gap.

## Immediate implementation sequence

1. Build a schema-only exporter that captures columns/defaults/identity, constraints, indexes, policies, triggers, function definitions/ACLs, view definitions, sequences and comments from catalogs; never export table data.
2. Generate the current-state fixture from this capture, mark it `DISPOSABLE ONLY — NOT A HISTORICAL MIGRATION` and keep it outside the active migration chain.
3. Add a CI job that starts a disposable PostgreSQL/Supabase service, replays the fixture, compares object fingerprints, then applies only the PR #200 draft SQL under test.
4. Add transaction rollback tests for hard-delete/soft-delete decisions, history retention, asset queue creation, path-lock race prevention and privileges.
5. Keep the historical clean-room migration replay gate open until pre-ledger source provenance is independently resolved.

## Safety boundary

No hosted DDL/DML, migration, Auth/Storage mutation, deployment, Cron activation, reset, or destructive action was performed. The connected Supabase test project remains read-only. PR #200 remains Draft / unmerged.

