# Security finding — excessive TRUNCATE grants on existing public tables

Date: 2026-11-01
Project: `ouyewoagbmtqehbofrje` (test only)
Discovery context: read-only Phase A/B catalog and privilege inventory during PR #200.
Severity: high-priority privilege-hardening issue; no direct exploit path through the ordinary Data API was established.
Status: confirmed excessive database grants; remediation not yet applied.

## Finding

A read-only catalog query of table ACLs and `has_table_privilege` found explicit `TRUNCATE` privileges granted to `anon` and/or `authenticated` on eight existing `public` tables. All eight have RLS enabled, but PostgreSQL `TRUNCATE` is not row-filtered by RLS.

| Table | anon TRUNCATE | authenticated TRUNCATE |
|---|---:|---:|
| author_follows | yes | yes |
| character_stories | yes | yes |
| characters | yes | yes |
| chat_group_diary | no | yes |
| chat_group_memory_photos | yes | yes |
| chat_sessions | yes | yes |
| conversations | yes | yes |
| messages | yes | yes |

The affected tables are owned by `postgres`; their current ACL strings explicitly include `anon=arwdDxtm/postgres` and/or `authenticated=arwdDxtm/postgres`. These are not merely inferred from RLS policy membership.

## Exploitability qualification

The inspection confirms excessive SQL-level table privileges, but **does not establish that an ordinary app user can execute TRUNCATE through the Supabase Data API**:

- Supabase `anon` and `authenticated` roles have `rolcanlogin=false`; they cannot log in directly to PostgreSQL.
- Ordinary PostgREST does not expose a generic TRUNCATE operation.
- A read-only scan of user-callable function bodies that contain `TRUNCATE` or dynamic `EXECUTE` found no direct `TRUNCATE` command in an app-callable SECURITY DEFINER function. Returned dynamic-SQL helpers were platform extension/realtime/storage functions marked SECURITY INVOKER. This was a targeted scan, not a full transitive call-graph proof.
- No exploit was attempted and no table was modified.

Therefore this is a confirmed least-privilege defect and a dangerous latent capability if an execution path later exposes it, **not a confirmed remotely exploitable data-wipe vulnerability from the current ordinary REST surface**.

## Related default-privilege finding

The repository migration `20261023040000_restrict_public_default_privileges.sql` contains:

```sql
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL PRIVILEGES ON TABLES FROM anon, authenticated;
```

The live migration history includes the corresponding migration name under a different version prefix (`20261023092154_restrict_public_default_privileges`). This default-privilege change affects future tables created by `postgres`; it does not retroactively remove grants from existing tables. The eight current ACLs therefore remain.

The catalog also shows a separate `supabase_admin` default ACL for `public` tables that includes anon/authenticated grants. Current affected tables are owned by postgres, and no change to Supabase-managed `supabase_admin` defaults is proposed here. Do not alter platform-managed default ACLs without a separate review.

## Proposed minimal remediation

Add a new reviewed migration that revokes only the table-level TRUNCATE privilege from client roles across the public schema:

```sql
REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
```

This leaves existing SELECT/INSERT/UPDATE/DELETE grants and RLS policies unchanged, and does not revoke privileges from `service_role` or `postgres`. Existing postgres default privileges already revoke all table privileges from anon/authenticated for future public-schema tables created by postgres.

Do not apply this remediation until the migration file has been created through the supported local migration workflow, reviewed, and matched to the remote migration operation. The current execution environment has no local Supabase CLI or Docker executable available to perform the required `supabase migration new` workflow; therefore this inspection did not execute the REVOKE.

## Required verification after a reviewed migration is applied to the test project

1. For every public table, `has_table_privilege('anon', table_oid, 'TRUNCATE')` and `has_table_privilege('authenticated', table_oid, 'TRUNCATE')` must both be false.
2. `service_role` and `postgres` retain expected administrative privileges.
3. RLS policy behavior and intended authenticated SELECT/INSERT/UPDATE flows remain unchanged.
4. Confirm no application RPC depends on client-role TRUNCATE (none identified by this targeted catalog inspection).
5. Re-run the privilege query and record the exact migration version plus before/after counts.

## Safety

- Read-only inspection only. No REVOKE has been executed.
- No table data, chat content, Storage objects, or user accounts were changed.
- No migration history was edited.
- Do not treat RLS as a substitute for revoking TRUNCATE: RLS does not protect TRUNCATE.
- This is a separate cross-table hardening item; it must be reviewed and tracked before production launch. PR #200 remains Draft; no cron and no production changes.
