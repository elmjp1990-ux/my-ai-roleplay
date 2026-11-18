# Current-state disposable schema catalog snapshot — captured 2026-11-02, fixture augmented 2026-11-19

**DISPOSABLE ONLY. NOT A HISTORICAL MIGRATION. NOT FOR PRODUCTION.**

Source: Supabase test project `ouyewoagbmtqehbofrje`.
Capture method: `supabase/drafts/export-disposable-schema-catalog.sql`, executed in a read-only transaction.
Latest capture: 2026-11-02T14:40:45.558798+00:00 (PostgreSQL 17.11).
No application table rows, profile contents, character contents, chat contents, wallet contents, or Storage objects were exported.\n\nFixture augmentation (2026-11-19): `current-state-structure.json` additionally includes the `suggested_replies` JSONB columns and their array/maximum-three CHECK constraints on `chat_messages` and `chat_group_turns`, based on the checked-in migrations `20261111100000_story_suggested_replies_persistence.sql` and `20261116150000_group_turn_suggested_replies.sql`. These two columns and constraints were not part of the original 2026-11-02 read-only capture; they are explicit schema-fixture augmentations, not a new hosted schema capture.

## Snapshot files

- `current-state-structure.json`: relations, columns/defaults/comments, constraints, indexes, views, sequences (including ownership), types and installed extensions.
- `current-state-routines.json`: exact definitions and metadata for public/private application routines, including owner, security-definer, volatility, search_path/config and ACL.
- `current-state-security.json`: RLS policies, triggers, table/column/routine/relation/sequence grants, schema ACLs and default privileges.

## Counts

| Catalog category | Count |
|---|---:|
| Relations (47 public tables + view + sequences + private objects) | 50 |
| Table columns | 412 |
| View columns | 6 |
| All relation columns | 418 |
| Constraints | 290 |
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

- This augmented snapshot is suitable only as input to a disposable current-state test fixture for PR #267 validation. It combines the original 2026-11-02 schema-only capture with the two explicitly documented suggested-reply column/constraint additions above; it is not a fresh live schema capture.
- Do not run historical migrations on top of this snapshot; later migrations would attempt to add objects that are already present.
- Supabase-managed `auth` and `storage` schemas are intentionally excluded and must come from the matching local Supabase bootstrap.
- The snapshot must be replayed only in a disposable PostgreSQL/Supabase environment. Compare the replayed object fingerprint before applying any draft SQL.
- This does not recover the original pre-`20261015065943` `profiles` / `characters` CREATE TABLE source and does not close the historical migration replay gate.
- No hosted DDL/DML, data mutation, Auth/Storage mutation, deployment or Cron change was performed.
