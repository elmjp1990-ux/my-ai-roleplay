#!/usr/bin/env bash
set -euo pipefail

: "\${DATABASE_URL:?DATABASE_URL is required}"

# Prove the migration can be applied atomically and fully rolled back on a
# disposable PostgreSQL 17.11 database before applying it for the real tests.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X <<'SQL'
BEGIN;
\i supabase/migrations/20261114180000_group_ai_single_orchestrator.sql
ROLLBACK;

DO $$
DECLARE
  v_constraint text;
BEGIN
  IF to_regprocedure('public.reserve_group_chat_turn(uuid,uuid,uuid,text)') IS NOT NULL
    OR to_regprocedure('public.complete_group_chat_turn(uuid,uuid,jsonb,jsonb)') IS NOT NULL
    OR to_regprocedure('public.expire_group_chat_turn(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('public.run_group_chat_turn_watchdog(integer)') IS NOT NULL
    OR to_regprocedure('public.refund_group_chat_turn(uuid,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'rollback left group transaction RPCs behind';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='chat_group_members' AND column_name='phone_notifications') THEN
    RAISE EXCEPTION 'rollback left group member phone_notifications column behind';
  END IF;

  IF to_regclass('public.chat_group_ai_usage') IS NOT NULL
    OR to_regclass('public.wallet_transactions_group_turn_idempotency_uidx') IS NOT NULL
    OR to_regclass('cron.job') IS NOT NULL
    OR EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE EXCEPTION 'rollback left migration objects or pg_cron enabled';
  END IF;

  SELECT pg_get_constraintdef(oid) INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.chat_group_turns'::regclass
    AND conname = 'chat_group_turns_status_check';
  IF v_constraint IS NULL OR v_constraint NOT LIKE '%completed%' OR v_constraint LIKE '%processing%' THEN
    RAISE EXCEPTION 'rollback did not restore the original group turn status constraint: %', v_constraint;
  END IF;

  SELECT pg_get_constraintdef(oid) INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.chat_group_turn_charges'::regclass
    AND conname = 'chat_group_turn_charges_status_check';
  IF v_constraint IS NULL OR v_constraint NOT LIKE '%settled%' OR v_constraint LIKE '%reserved%' THEN
    RAISE EXCEPTION 'rollback did not restore the original group charge status constraint: %', v_constraint;
  END IF;
END
$$;
SQL

echo "Group chat migration transaction rollback test passed."
