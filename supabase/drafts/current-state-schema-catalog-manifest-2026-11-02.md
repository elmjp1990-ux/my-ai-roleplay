# Current-state disposable schema catalog snapshot — 2026-11-02

**DISPOSABLE ONLY. NOT A HISTORICAL MIGRATION. NOT FOR PRODUCTION.**

Source: Supabase test project `ouyewoagbmtqehbofrje`.
Capture method: `supabase/drafts/export-disposable-schema-catalog.sql`, executed in a read-only transaction.
No application table rows, profile contents, character contents, chat contents, wallet contents, or Storage objects were exported.

## Snapshot files

- `current-state-structure.json`: relations, columns/defaults/comments, constraints, indexes, views, sequences, types and installed extensions.
- `current-state-routines.json`: exact definitions, metadata and direct ACLs for public/private application routines.
- `current-state-security.json`: RLS policies, triggers, direct relation/column/sequence/schema ACLs and default privileges.
- `current-state-effective-grants.json`: information_schema effective table, column and routine privilege listings for comparison.

## Counts

| Catalog category | Count |
|---|---:|
| Relations (47 tables + view + sequences) | 50 |
| Columns | 416 |
| Constraints | 288 |
| Indexes | 140 |
| RLS policies | 95 |
| Triggers | 23 |
| Application routines | 77 |
| Views | 1 |
| Sequences | 2 |
| Installed extensions | 7 |
| Direct relation ACL records | 937 |
| Direct column ACL records | 17 |
| Sequence ACL records | 18 |
| Schema ACL records | 2 schemas |
| Default ACL records | 6 |
| Effective table privilege records | 810 |
| Effective column privilege records | 4147 |
| Effective routine privilege records | 194 |

## Safety and replay rules

- This snapshot represents the **current** test schema after recorded migrations and manual drift. It is suitable only as input to a disposable current-state test fixture for PR #200 draft SQL.
- Do not run historical migrations on top of this snapshot; later migrations would attempt to add objects already present.
- Supabase-managed `auth` and `storage` schemas are intentionally excluded and must come from the matching local Supabase bootstrap.
- The snapshot must be replayed only in a disposable PostgreSQL/Supabase environment. Compare the replayed object fingerprint before applying any draft SQL.
- This does not recover the original pre-`20261015065943` `profiles` / `characters` CREATE TABLE source and does not close the historical migration replay gate.
- No hosted DDL/DML, data mutation, Auth/Storage mutation, deployment or Cron change was performed.

