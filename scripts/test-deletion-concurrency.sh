#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required}"
tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

wait_for_activity() {
  local app="$1"
  local query="$2"
  for _ in $(seq 1 40); do
    if [[ "$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = '$app' AND state = 'active' AND query LIKE '%$query%')")" == "t" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "ERROR: timed out waiting for PostgreSQL session $app to reach $query"
  return 1
}

wait_for_lock() {
  local app="$1"
  for _ in $(seq 1 40); do
    if [[ "$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = '$app' AND state = 'active' AND wait_event_type = 'Lock')")" == "t" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "ERROR: timed out waiting for PostgreSQL session $app to wait on a row lock"
  return 1
}

author="10000000-0000-4000-8000-000000000030"
player="10000000-0000-4000-8000-000000000031"
delete_character="20000000-0000-4000-8000-000000000030"
archive_character="20000000-0000-4000-8000-000000000031"
schedule_id="40000000-0000-4000-8000-000000000031"
race_session="50000000-0000-4000-8000-000000000030"

# Race 1: character deletion takes the parent FOR UPDATE lock first. The new
# session trigger must wait on FOR KEY SHARE, then observe deleted_at and reject.
cat > "$tmpdir/delete-owner.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$author","role":"authenticated"}', true);
SELECT id FROM public.characters WHERE id = '$delete_character' FOR UPDATE;
SELECT pg_sleep(2);
SELECT public.soft_delete_character('$delete_character');
COMMIT;
SQL

cat > "$tmpdir/new-session.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$player', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$player","role":"authenticated"}', true);
INSERT INTO public.chat_sessions (
  id, user_id, character_id, character_name, chat_mode
) VALUES (
  '$race_session', '$player', '$delete_character', 'Delete race character', 'story'
);
COMMIT;
SQL

PGAPPNAME=pr200-delete-owner psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/delete-owner.sql" >"$tmpdir/delete-owner.log" 2>&1 &
delete_pid=$!
wait_for_activity "pr200-delete-owner" "pg_sleep(2)"
if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/new-session.sql" >"$tmpdir/new-session.log" 2>&1; then
  echo "ERROR: new session insert unexpectedly succeeded while character deletion won the lock"
  cat "$tmpdir/new-session.log"
  exit 1
fi
wait "$delete_pid"
if ! grep -q "character_not_available" "$tmpdir/new-session.log"; then
  echo "ERROR: competing new session did not fail at the archived/deleted character guard"
  cat "$tmpdir/new-session.log"
  exit 1
fi

delete_state="$(psql "$DATABASE_URL" -Atqc "SELECT deleted_at IS NOT NULL FROM public.characters WHERE id = '$delete_character'")"
session_exists="$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM public.chat_sessions WHERE id = '$race_session')")"
[[ "$delete_state" == "t" && "$session_exists" == "f" ]] || {
  echo "ERROR: character deletion/new-session race left an invalid final state"
  exit 1
}
echo "ok: character deletion serializes against new session insert"

# Race 2: an authenticated child-row update starts before the deletion request
# is committed and holds the schedule row. prepare_account_deletion must wait,
# then archive the character without losing the already-committed child write.
cat > "$tmpdir/child-writer.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$author","role":"authenticated"}', true);
UPDATE public.character_schedules
SET activity = 'Concurrent child update committed before archive'
WHERE id = '$schedule_id';
SELECT pg_sleep(2);
COMMIT;
SQL

cat > "$tmpdir/account-archive.sql" <<SQL
BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.sub', '$author', true);
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claims', '{"sub":"$author","role":"service_role"}', true);
INSERT INTO public.account_deletion_requests (user_id, requested_at, scheduled_for)
VALUES ('$author', now() - interval '1 hour', now() - interval '1 minute');
SELECT batch_status FROM public.prepare_account_deletion('$author');
COMMIT;
SQL

PGAPPNAME=pr200-child-writer psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/child-writer.sql" >"$tmpdir/child-writer.log" 2>&1 &
child_pid=$!
wait_for_activity "pr200-child-writer" "pg_sleep(2)"
PGAPPNAME=pr200-account-archive psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/account-archive.sql" >"$tmpdir/account-archive.log" 2>&1 &
archive_pid=$!
wait_for_lock "pr200-account-archive"
wait "$child_pid"
wait "$archive_pid"

archive_state="$(psql "$DATABASE_URL" -Atqc "SELECT author_id IS NULL AND account_archived_at IS NOT NULL FROM public.characters WHERE id = '$archive_character'")"
child_value="$(psql "$DATABASE_URL" -Atqc "SELECT activity FROM public.character_schedules WHERE id = '$schedule_id'")"
[[ "$archive_state" == "t" && "$child_value" == "Concurrent child update committed before archive" ]] || {
  echo "ERROR: account archive/child-write race lost the in-flight child update or failed to archive"
  cat "$tmpdir/child-writer.log" "$tmpdir/account-archive.log"
  exit 1
}

# Once the account deletion request is committed, later author writes must be
# blocked by the restrictive account_is_active RLS policy.
cat > "$tmpdir/post-archive-write.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$author","role":"authenticated"}', true);
DO \$\$
DECLARE
  v_updated integer;
BEGIN
  UPDATE public.character_schedules
  SET activity = 'MUST NOT OVERWRITE ARCHIVED CHILD'
  WHERE id = '$schedule_id';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 0 THEN
    RAISE EXCEPTION 'post_archive_child_write_must_be_rejected';
  END IF;
END;
\$\$;
SQL
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/post-archive-write.sql" >/dev/null
child_value="$(psql "$DATABASE_URL" -Atqc "SELECT activity FROM public.character_schedules WHERE id = '$schedule_id'")"
[[ "$child_value" == "Concurrent child update committed before archive" ]] || {
  echo "ERROR: child write was accepted after account archival"
  exit 1
}
echo "ok: account archival serializes against in-flight child write and blocks later writes"


# Race 3: a live illustration reference wins the advisory path lock first.
# Character deletion must wait, enqueue the path after the reattachment commits,
# and leave the new reference intact for the worker's reference-check to skip.
asset_author="10000000-0000-4000-8000-000000000032"
asset_path_a="$asset_author/20000000-0000-4000-8000-000000000032/30000000-0000-4000-8000-000000000032.jpg"
cat > "$tmpdir/asset-reattach-first.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$asset_author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$asset_author","role":"authenticated"}', true);
INSERT INTO public.character_illustrations (
  id, character_id, author_id, storage_path, asset_type, sort_order
) VALUES (
  '30000000-0000-4000-8000-000000000033',
  '20000000-0000-4000-8000-000000000033',
  '$asset_author', '$asset_path_a', 'primary', 0
);
SELECT pg_sleep(2);
COMMIT;
SQL
cat > "$tmpdir/asset-delete-after-reattach.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$asset_author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$asset_author","role":"authenticated"}', true);
SELECT public.soft_delete_character('20000000-0000-4000-8000-000000000032');
COMMIT;
SQL

PGAPPNAME=pr200-asset-reattach-first psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/asset-reattach-first.sql" >"$tmpdir/asset-reattach-first.log" 2>&1 &
reattach_pid=$!
wait_for_activity "pr200-asset-reattach-first" "pg_sleep(2)"
PGAPPNAME=pr200-asset-delete-after psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/asset-delete-after-reattach.sql" >"$tmpdir/asset-delete-after.log" 2>&1 &
asset_delete_pid=$!
wait_for_lock "pr200-asset-delete-after"
wait "$reattach_pid"
wait "$asset_delete_pid"
asset_a_queued="$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM public.character_asset_cleanup_jobs WHERE bucket_id='character-illustrations' AND object_path='$asset_path_a')")"
asset_a_referenced="$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM public.character_illustrations WHERE storage_path='$asset_path_a')")"
[[ "$asset_a_queued" == "t" && "$asset_a_referenced" == "t" ]] || {
  echo "ERROR: reattachment-first race did not preserve the live reference and enqueue cleanup"
  cat "$tmpdir/asset-reattach-first.log" "$tmpdir/asset-delete-after.log"
  exit 1
}
echo "ok: asset reattachment wins path lock; cleanup sees a still-referenced object"

# Race 4: deletion owns the path lock first. A later attempt to attach that path
# must wait until the cleanup row is committed, then fail in the BEFORE trigger.
asset_path_b="$asset_author/20000000-0000-4000-8000-000000000034/30000000-0000-4000-8000-000000000034.jpg"
cat > "$tmpdir/asset-delete-first.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$asset_author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$asset_author","role":"authenticated"}', true);
SELECT private.lock_character_asset_path('character-illustrations', '$asset_path_b');
SELECT pg_sleep(2);
SELECT public.soft_delete_character('20000000-0000-4000-8000-000000000034');
COMMIT;
SQL
cat > "$tmpdir/asset-reattach-after-delete.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$asset_author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$asset_author","role":"authenticated"}', true);
INSERT INTO public.character_illustrations (
  id, character_id, author_id, storage_path, asset_type, sort_order
) VALUES (
  '30000000-0000-4000-8000-000000000035',
  '20000000-0000-4000-8000-000000000035',
  '$asset_author', '$asset_path_b', 'primary', 0
);
COMMIT;
SQL

PGAPPNAME=pr200-asset-delete-first psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/asset-delete-first.sql" >"$tmpdir/asset-delete-first.log" 2>&1 &
asset_delete_first_pid=$!
wait_for_activity "pr200-asset-delete-first" "pg_sleep(2)"
if PGAPPNAME=pr200-asset-reattach-after psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/asset-reattach-after-delete.sql" >"$tmpdir/asset-reattach-after-delete.log" 2>&1; then
  echo "ERROR: reattachment unexpectedly succeeded after cleanup path was queued"
  exit 1
fi
wait "$asset_delete_first_pid"
if ! grep -q "character_asset_path_cleanup_already_queued" "$tmpdir/asset-reattach-after-delete.log"; then
  echo "ERROR: queued asset path reattachment did not fail at the cleanup guard"
  cat "$tmpdir/asset-reattach-after-delete.log"
  exit 1
fi
asset_b_queued="$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM public.character_asset_cleanup_jobs WHERE bucket_id='character-illustrations' AND object_path='$asset_path_b')")"
asset_b_referenced="$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM public.character_illustrations WHERE storage_path='$asset_path_b')")"
[[ "$asset_b_queued" == "t" && "$asset_b_referenced" == "f" ]] || {
  echo "ERROR: delete-first race left an invalid queued/referenced path state"
  exit 1
}
echo "ok: deletion wins path lock; queued asset path cannot be reattached"

echo "Deletion concurrency tests: 4 passed, 0 failed"
