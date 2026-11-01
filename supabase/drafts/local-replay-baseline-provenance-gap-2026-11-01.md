# Local replay baseline provenance gap — 2026-11-01

Repository: elmjp1990-ux/my-ai-roleplay
Working branch: security/chat-deletion-lifecycle-reconciliation
Connected Supabase test project: ouyewoagbmtqehbofrje

## Observed clean-replay failure

The manual GitHub Actions run `41317008736` checked out PR #200 commit `a16f4c238774ca4b002bdd514891788e5fe8da8b`, started a disposable local Supabase stack, then failed during `supabase db reset --local --no-seed` at the first repository migration:

- `20261015141259_group_chat_core_schema.sql`
- Error: `relation "public.characters" does not exist` (SQLSTATE 42P01)
- Failing dependency: `chat_group_members.character_id REFERENCES public.characters(id)`

No security draft migration was applied. The local stack was stopped with `supabase stop --no-backup`.

## Provenance checks

Read-only inspection of the connected test project's migration ledger shows the earliest recorded version is:

- `20261015065943 / isolate_character_private_info`

The SQL statements stored for that migration create `public.character_private_info` with foreign keys to existing `public.characters` and `public.profiles`, then copy private fields from `public.characters`. It does not create either foundational table.

Git history shows the earliest repository migration commit:

- `0d3eb335d0fed12ed0048123c279159dab2135b9`
- `Add character soft-delete schema and secure RPCs`
- Its migration source `20261015_character_soft_delete.sql` starts with `ALTER TABLE public.characters ADD COLUMN ...`; it assumes `public.characters` already exists.

The repository's migration directory has no base-schema migration or schema dump that creates `public.characters` / `public.profiles`. The group core migration therefore depends on a schema created before the checked-in migration chain, likely through an earlier manual/bootstrap process. The exact original SQL source has not been recovered.

Earlier project conversations from 2026-10-14 and 2026-10-15 also confirm that `public.characters` and `public.profiles` already existed and that their live column inventories were inspected (including character identity/visibility/deletion fields and profile identity/display fields). Those conversations did not contain the original `CREATE TABLE` statements, complete defaults/constraints/indexes, or a schema/bootstrap file. The column inventory is evidence of shape only and is not sufficient to recreate a safe baseline.

## Consequence

The current GitHub migration chain is not reproducible from an empty database. Do not:
- rename or reorder historical migrations to make the first replay error disappear;
- create a guessed `characters` table with only the columns needed by the first failing FK;
- run hosted `db push`, `db reset`, `migration repair`, `migration down`, or manually edit `supabase_migrations.schema_migrations`;
- treat the two PR #200 security drafts as tested because the workflow never reached them.

## Safe recovery options to evaluate

1. Recover the original foundational schema SQL from the original Supabase SQL Editor / project bootstrap history, if available.
2. If that source cannot be recovered, create a separately reviewed, complete, schema-only baseline snapshot from the connected test project and make the local replay workflow explicitly distinguish:
   - baseline bootstrap (schema only, no production/user data);
   - migration history replay from the earliest reproducible point;
   - PR #200 draft migrations and fixture tests.
3. Validate the baseline against all application-owned tables, columns, constraints, indexes, triggers, functions, RLS policies, grants, extensions, Storage buckets/policies, and required settings. Do not treat a table-only export as a complete baseline.

The Supabase MCP connection currently exposes one test project. This does not prove no other unlinked environment exists. Any baseline snapshot must be labeled as test-project-derived and must not be promoted to production without a separate provenance review.

## Status

- No hosted database was modified.
- No new Supabase Cloud Branch or paid environment was created.
- No cron was enabled.
- PR #200 remains Draft/unmerged.
- This note records evidence and recovery options only; it is not an executable migration.
