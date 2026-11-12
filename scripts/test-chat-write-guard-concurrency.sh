#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL must point to the disposable local Supabase database}"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

wait_for_sleep_query() {
  local app_name="$1"
  local attempt
  for attempt in $(seq 1 100); do
    if [[ "$(psql "$DATABASE_URL" -X -A -t -q -c \
      "SELECT 1 FROM pg_stat_activity WHERE application_name='$app_name' AND state='active' AND query LIKE 'SELECT pg_sleep(3)%' LIMIT 1")" == "1" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "Timed out waiting for transaction $app_name to hold its parent lock."
  return 1
}

# Both sessions use separate psql processes, so these are real independent
# PostgreSQL transactions rather than sequential statements in one connection.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/drafts/setup-chat-write-guard-concurrency.sql

# Race A: deletion acquires the parent lock first. The assistant writer must
# wait, re-check the now-deleted parent, and fail without persisting a reply.
PGAPPNAME=write-guard-delete-first psql "$DATABASE_URL" -v ON_ERROR_STOP=1 >"$tmp_dir/delete-first.log" 2>&1 <<'SQL' &
BEGIN;
UPDATE public.chat_sessions
SET deleted_at=now()
WHERE id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1';
SELECT pg_sleep(3);
COMMIT;
SQL
delete_pid=$!
wait_for_sleep_query "write-guard-delete-first"

started_ms="$(date +%s%3N)"
if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 >"$tmp_dir/writer-after-delete.log" 2>&1 <<'SQL'
BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role','service_role',true);
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
INSERT INTO public.chat_messages (id,session_id,role,content)
VALUES ('e3000000-0000-4000-8000-000000000001',
        'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1',
        'assistant','must be rejected after deletion');
COMMIT;
SQL
then
  echo "Race A failed: assistant insert unexpectedly succeeded after deletion."
  wait "$delete_pid" || true
  exit 1
fi
finished_ms="$(date +%s%3N)"
wait "$delete_pid"

elapsed_ms=$((finished_ms - started_ms))
if (( elapsed_ms < 1500 )); then
  echo "Race A did not wait for the parent lock (elapsed ${elapsed_ms}ms)."
  cat "$tmp_dir/writer-after-delete.log"
  exit 1
fi
grep -q "chat_session_not_found_or_deleted" "$tmp_dir/writer-after-delete.log"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $body$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.chat_messages
    WHERE id='e3000000-0000-4000-8000-000000000001'
  ) THEN
    RAISE EXCEPTION 'Race A persisted an assistant reply after parent deletion';
  END IF;
  IF (SELECT status FROM public.chat_turn_charges
      WHERE turn_id='e2000000-0000-4000-8000-000000000001') <> 'reserved' THEN
    RAISE EXCEPTION 'Race A unexpectedly changed the charge state';
  END IF;
END;
$body$;
SQL

# Race B: assistant writer acquires the parent lock first. Deletion must wait
# until the durable assistant insert commits, then soft-delete the parent.
PGAPPNAME=write-guard-writer-first psql "$DATABASE_URL" -v ON_ERROR_STOP=1 >"$tmp_dir/writer-first.log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role','service_role',true);
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
INSERT INTO public.chat_messages (id,session_id,role,content)
VALUES ('e3000000-0000-4000-8000-000000000002',
        'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2',
        'assistant','writer acquired parent lock first');
SELECT pg_sleep(3);
COMMIT;
SQL
writer_pid=$!
wait_for_sleep_query "write-guard-writer-first"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 >"$tmp_dir/delete-after-writer.log" 2>&1 <<'SQL' &
BEGIN;
UPDATE public.chat_sessions
SET deleted_at=now()
WHERE id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2';
COMMIT;
SQL
delete_after_writer_pid=$!

wait "$writer_pid"
wait "$delete_after_writer_pid"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $body$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_messages
    WHERE id='e3000000-0000-4000-8000-000000000002'
      AND role='assistant'
      AND content='writer acquired parent lock first'
  ) THEN
    RAISE EXCEPTION 'Race B lost the assistant reply that committed before deletion';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_sessions
    WHERE id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2'
      AND deleted_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Race B did not complete the queued parent deletion update';
  END IF;
END;
$body$;
SQL

echo "Chat write guard two-connection parent-lock races passed (delete-first waited ${elapsed_ms}ms)."
