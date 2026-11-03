-- Disposable-only local Supabase replay from the synthetic current-state schema.
-- This deliberately does NOT replay the incomplete historical migration chain.
-- The transaction is always rolled back; no application rows or Storage objects are retained.
\set ON_ERROR_STOP on
BEGIN;

CREATE SCHEMA IF NOT EXISTS storage;
DO $storage_stub$
BEGIN
  IF pg_catalog.to_regclass('storage.objects') IS NULL THEN
    CREATE TABLE storage.objects (bucket_id text NOT NULL, name text NOT NULL);
  END IF;
END;
$storage_stub$;

\echo 'Applying cumulative chat deletion turn-statistics draft'
\i supabase/drafts/chat-deletion-cumulative-turn-statistics-proposal.sql

\echo 'Applying archived-group memory-photo read-access correction'
\i supabase/drafts/chat-archive-memory-photo-read-access.sql
\i supabase/drafts/test-chat-archive-memory-photo-read-access.sql

\echo 'Applying Encounter settlement parent-first lock reconciliation'
\i supabase/drafts/settle-encounter-session-parent-lock-live-reconciliation.sql

\echo 'Applying Encounter session deletion lifecycle guards'
\i supabase/drafts/encounter-session-delete-lifecycle-guards.sql

\echo 'Applying Encounter diary chat deletion visibility guard'
\i supabase/drafts/encounter-diary-chat-deletion-lifecycle-guard.sql

\echo 'Applying Encounter evaluation deletion gate'
\i supabase/drafts/encounter-evaluation-deletion-gate-proposal.sql

\echo 'Revoking direct client TRUNCATE privileges'
\i supabase/drafts/revoke-public-truncate-privileges-proposal.sql

\echo 'Verifying cumulative turn-statistics structure, owner, RLS, ACL and search_path'
\i supabase/drafts/chat-deletion-turn-stats-structural-verification.sql

\echo 'Auditing Encounter lifecycle trigger attachments and ACLs'
\i supabase/drafts/encounter-lifecycle-trigger-attachment-audit.sql

\echo 'Local synthetic security-draft replay complete; rollback all DDL'
ROLLBACK;
