# Current-state disposable schema catalog snapshot — 2026-11-02

**DISPOSABLE ONLY. NOT A HISTORICAL MIGRATION. NOT FOR PRODUCTION.**

Source: Supabase test project `ouyewoagbmtqehbofrje`.
Capture method: `supabase/drafts/export-disposable-schema-catalog.sql`, executed in a read-only transaction.
Latest capture: 2026-11-02T14:40:45.558798+00:00 (PostgreSQL 17.11).
No application table rows, profile contents, character contents, chat contents, wallet contents, or Storage objects were exported.

## Snapshot files

- `current-state-structure.json`: relations, columns/defaults/comments, constraints, indexes, views, sequences (including ownership), types and installed extensions.
- `current-state-routines.json`: exact definitions and metadata for public/private application routines, including owner, security-definer, volatility, search_path/config and ACL.
- `current-state-security.json`: RLS policies, triggers, table/column/routine/relation/sequence grants, schema ACLs and default privileges.

## Counts

| Catalog category | Count |
|---|---:|
| Relations (47 public tables + view + sequences + private objects) | 50 |
| Table columns | 410 |
| View columns | 6 |
| All relation columns | 416 |
| Constraints | 288 |
| Indexes | 140 |
| RLS policies | 95 |
| Triggers | 23 |
| Application routines | 77 |
| Views | 1 |
| Sequences | 2 |
| Relation privilege records | 937 |
| Table privilege records | 810 |
| Column privilege records | 4147 |
| Routine privilege records | 194 |
| Sequence privilege records | 18 |
| Schema privilege records | 2 |
| Default privilege records | 6 |
| Installed extensions | 7 |

## Safety and replay rules

- This snapshot represents the **current** test schema after the recorded migrations and manual drift. It is suitable only as input to a disposable current-state test fixture for PR #200 draft SQL.
- Do not run historical migrations on top of this snapshot; later migrations would attempt to add objects that are already present.
- Supabase-managed `auth` and `storage` schemas are intentionally excluded and must come from the matching local Supabase bootstrap.
- The snapshot must be replayed only in a disposable PostgreSQL/Supabase environment. Compare the replayed object fingerprint before applying any draft SQL.
- This does not recover the original pre-`20261015065943` `profiles` / `characters` CREATE TABLE source and does not close the historical migration replay gate.
- No hosted DDL/DML, data mutation, Auth/Storage mutation, deployment or Cron change was performed.
