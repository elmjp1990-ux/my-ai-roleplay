-- Apply both deletion drafts and execute behavior tests inside one disposable transaction.
-- The final ROLLBACK removes every draft object and every synthetic test row.
\set ON_ERROR_STOP on
BEGIN;
\echo 'Applying cumulative chat deletion character-history snapshot draft'
\i supabase/drafts/chat-deletion-cumulative-turn-statistics-proposal.sql
\echo 'Seeding legacy character rows before the publication/origin triggers exist'
\i supabase/drafts/seed-character-deletion-legacy-fixtures.sql
\echo 'Applying character history-aware deletion draft'
\i supabase/drafts/character-history-aware-deletion.sql
\echo 'Applying existing-chat continuation writer draft (single/group deletion behavior remains isolated to disposable replay)'
\i supabase/drafts/character-deletion-existing-chat-continuation.sql
\echo 'Verifying draft tables, triggers, RLS and ACLs before behavior tests'
\i supabase/drafts/verify-deletion-draft-replay.sql
\echo 'Running hard-delete, soft-delete, single/group continuation, history, publication and asset path behavior tests'
\i supabase/drafts/test-character-deletion-behavior.sql
\echo 'All disposable character deletion behavior assertions passed; rolling back all draft DDL and test rows'
ROLLBACK;
