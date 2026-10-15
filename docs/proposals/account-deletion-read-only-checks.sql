-- READ-ONLY DIAGNOSTICS ONLY. Safe to inspect in Supabase SQL Editor.
-- Do not add UPDATE/DELETE/INSERT statements to this file.

-- 1) Request and archive lifecycle state counts.
SELECT 'requests' AS item, count(*)::bigint AS total, NULL::text AS status
FROM public.account_deletion_requests
UNION ALL
SELECT 'archive_batches', count(*)::bigint, status
FROM public.account_deletion_archive_batches
GROUP BY status
ORDER BY item, status;

-- 2) Inspect request deadlines without exposing user identifiers.
SELECT
  CASE
    WHEN scheduled_for > statement_timestamp() THEN 'future'
    ELSE 'expired'
  END AS deadline_state,
  count(*)::bigint AS total
FROM public.account_deletion_requests
GROUP BY 1
ORDER BY 1;

-- 3) Compare archived item counts with the source rows for each batch.
-- This intentionally reports only aggregate counts, not payloads or user IDs.
SELECT
  b.status,
  i.source_table,
  count(i.id)::bigint AS archived_item_count
FROM public.account_deletion_archive_batches AS b
LEFT JOIN public.account_deletion_archive_items AS i ON i.batch_id = b.id
GROUP BY b.status, i.source_table
ORDER BY b.status, i.source_table;

-- 4) RLS policies for account-deletion and user-data tables.
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'account_deletion_requests',
    'account_deletion_archive_batches',
    'account_deletion_archive_items',
    'ai_generation_records',
    'chat_sessions',
    'chat_messages',
    'chat_message_versions',
    'characters',
    'character_stories',
    'conversations',
    'messages',
    'profiles',
    'wallet_accounts',
    'wallet_transactions'
  )
ORDER BY tablename, policyname;

-- 5) Foreign keys touching the audited public tables.
SELECT
  child_ns.nspname AS child_schema,
  child.relname AS child_table,
  con.conname AS constraint_name,
  parent_ns.nspname AS parent_schema,
  parent.relname AS parent_table,
  pg_get_constraintdef(con.oid) AS definition
FROM pg_constraint AS con
JOIN pg_class AS child ON child.oid = con.conrelid
JOIN pg_namespace AS child_ns ON child_ns.oid = child.relnamespace
JOIN pg_class AS parent ON parent.oid = con.confrelid
JOIN pg_namespace AS parent_ns ON parent_ns.oid = parent.relnamespace
WHERE con.contype = 'f'
  AND (child_ns.nspname = 'public' OR parent_ns.nspname = 'public')
ORDER BY child_schema, child_table, constraint_name;

-- 6) Verify the production default explicitly. This query does not change it.
SELECT column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'account_deletion_requests'
  AND column_name = 'scheduled_for';
