# Account deletion — archive access-control verification — Round 48 addendum — 2026-11-02

Read-only verification of `account_deletion_archive_batches` and `account_deletion_archive_items` on the connected test project:

- RLS is enabled on both tables.
- `relforcerowsecurity = false` on both (table owner / SECURITY DEFINER behavior must still be assessed separately).
- `pg_policies` returned no policies for either table.
- `information_schema.role_table_grants` returned only postgres table grants; no anon/authenticated/service_role table grants were listed.
- Indexes include batch primary key, unique (batch_id, source_table, source_record_id), batch lookup, retention_until lookup, and one active batch per target_user_id.

Interpretation:
- The archive payload tables are not exposed to ordinary anon/authenticated access via table grants/policies in the current catalog state.
- The archive RPCs are SECURITY DEFINER, so their execute ACLs and any functions that read archive payloads remain the real privileged access boundary. Must enumerate all routines with references to archive tables and verify EXECUTE grants before accepting.
- RLS enabled without policies is good defense in depth for ordinary roles but does not protect against table owner or SECURITY DEFINER functions that bypass RLS.
- `retention_until` is indexed but nullable; this does not prove a retention cleanup process exists. Search all scheduled jobs/functions for actual archive expiry behavior before launch.
- Do not infer that the archive is permanently retained just because no user grants are present.

No hosted writes, RPC invocation, DDL/DML, Auth/Storage changes, deployment, or Cron changes.
