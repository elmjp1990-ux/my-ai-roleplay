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
lease_author="10000000-0000-4000-8000-000000000033"

# Lease race: two independent sessions contend for one due account request.
# Session A holds its transaction open after claim; session B must skip the
# locked request, then still see no work after A commits because the lease is active.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<SQL
INSERT INTO public.account_deletion_requests (user_id, requested_at, scheduled_for)
VALUES ('$lease_author', now() - interval '1 hour', now() - interval '1 minute');
SQL
cat > "$tmpdir/lease-claim-first.sql" <<SQL
BEGIN;
DO \$\$
DECLARE v_count integer;
BEGIN
  SELECT count(*)::integer INTO v_count
  FROM public.claim_account_deletion_work_items(1);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'first_worker_must_claim_exactly_one_request';
  END IF;
END;
\$\$;
SELECT pg_sleep(2);
COMMIT;
SQL
PGAPPNAME=pr200-lease-claim-first psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/lease-claim-first.sql" >"$tmpdir/lease-claim-first.log" 2>&1 &
lease_first_pid=$!
wait_for_activity "pr200-lease-claim-first" "pg_sleep(2)"
second_claim_during_lock="$(psql "$DATABASE_URL" -Atqc "SELECT count(*) FROM public.claim_account_deletion_work_items(1)")"
wait "$lease_first_pid"
second_claim_after_commit="$(psql "$DATABASE_URL" -Atqc "SELECT count(*) FROM public.claim_account_deletion_work_items(1)")"
[[ "$second_claim_during_lock" == "0" && "$second_claim_after_commit" == "0" ]] || {
  echo "ERROR: competing worker obtained duplicate account deletion work"
  cat "$tmpdir/lease-claim-first.log"
  exit 1
}
echo "ok: exactly one concurrent worker claims a due account deletion request"

# An active lease for the oldest request must not starve a different due account.
fair_author="10000000-0000-4000-8000-000000000034"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "INSERT INTO public.account_deletion_requests (user_id, requested_at, scheduled_for) VALUES ('$fair_author', now() - interval '1 hour', now() - interval '1 minute')" >/dev/null
fair_claim="$(psql "$DATABASE_URL" -Atqc "SELECT target_user_id::text FROM public.claim_account_deletion_work_items(1)")"
[[ "$fair_claim" == "$fair_author" ]] || {
  echo "ERROR: an active lease on an earlier request starved another due request"
  exit 1
}
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "UPDATE public.account_deletion_work_leases SET lease_expires_at=now()-interval '1 second' WHERE target_user_id='$fair_author'" >/dev/null
cat > "$tmpdir/fair-request-cancel.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$fair_author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$fair_author","role":"authenticated"}', true);
SELECT public.cancel_account_deletion();
COMMIT;
SQL
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/fair-request-cancel.sql" >/dev/null
echo "ok: active older leases do not starve other due account requests"

# Expired lease reclaim must rotate both token and generation. The previous
# owner must be unable to renew or write failure metadata after reclaim.
old_lease="$(psql "$DATABASE_URL" -Atqc "SELECT lease_token::text || '|' || lease_generation::text FROM public.account_deletion_work_leases WHERE target_user_id='$lease_author'")"
old_token="${old_lease%%|*}"
old_generation="${old_lease##*|}"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "UPDATE public.account_deletion_work_leases SET lease_expires_at=now()-interval '1 second' WHERE target_user_id='$lease_author'" >/dev/null
new_lease="$(psql "$DATABASE_URL" -Atqc "SELECT lease_token::text || '|' || lease_generation::text FROM public.claim_account_deletion_work_items(1)")"
new_token="${new_lease%%|*}"
new_generation="${new_lease##*|}"
[[ -n "$new_token" && "$new_token" != "$old_token" && "$new_generation" == "$((old_generation + 1))" ]] || {
  echo "ERROR: expired lease reclaim did not rotate token and increment generation"
  exit 1
}
stale_renew="$(psql "$DATABASE_URL" -Atqc "SELECT public.renew_account_deletion_lease('$lease_author', '$old_token', $old_generation)")"
stale_failure="$(psql "$DATABASE_URL" -Atqc "SELECT public.record_account_deletion_failure_leased('$lease_author', NULL, '$old_token', $old_generation, 'stale_worker')")"
[[ "$stale_renew" == "f" && "$stale_failure" == "f" ]] || {
  echo "ERROR: stale worker was able to renew or write failure metadata"
  exit 1
}
echo "ok: expired lease is reclaimed with a new fencing generation; stale owner is rejected"

# The same stale generation must also be rejected by the destructive prepare
# and finalize wrappers, not only by renew/failure telemetry.
cat > "$tmpdir/stale-fenced-rpcs.sql" <<SQL
DO \$\$
BEGIN
  BEGIN
    PERFORM * FROM public.prepare_account_deletion_leased(
      '$lease_author', '$old_token'::uuid, $old_generation::bigint
    );
    RAISE EXCEPTION 'stale_prepare_unexpectedly_succeeded';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    NULL;
  END;

  BEGIN
    PERFORM public.finalize_account_deletion_leased(
      '$lease_author', 'ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid,
      '$old_token'::uuid, $old_generation::bigint
    );
    RAISE EXCEPTION 'stale_finalize_unexpectedly_succeeded';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    NULL;
  END;
END;
\$\$;
SQL
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/stale-fenced-rpcs.sql" >/dev/null
echo "ok: stale generation cannot prepare or finalize an account deletion"

# An active lease blocks player cancellation. Once the lease expires and no
# archive batch exists, cancellation can win and leaves the durable lease cancelled.
cat > "$tmpdir/active-lease-cancel.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$lease_author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$lease_author","role":"authenticated"}', true);
SELECT public.cancel_account_deletion();
COMMIT;
SQL
if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/active-lease-cancel.sql" >"$tmpdir/active-lease-cancel.log" 2>&1; then
  echo "ERROR: cancellation unexpectedly succeeded while a worker held an active lease"
  exit 1
fi
if ! grep -q "刪除處理已由背景工作領取" "$tmpdir/active-lease-cancel.log"; then
  echo "ERROR: active-lease cancellation failed for an unexpected reason"
  cat "$tmpdir/active-lease-cancel.log"
  exit 1
fi
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "UPDATE public.account_deletion_work_leases SET lease_expires_at=now()-interval '1 second' WHERE target_user_id='$lease_author'" >/dev/null
cat > "$tmpdir/expired-lease-cancel.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$lease_author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$lease_author","role":"authenticated"}', true);
SELECT public.cancel_account_deletion();
COMMIT;
SQL
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/expired-lease-cancel.sql" >/dev/null
cancel_state="$(psql "$DATABASE_URL" -Atqc "SELECT lease_status FROM public.account_deletion_work_leases WHERE target_user_id='$lease_author'")"
request_exists="$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM public.account_deletion_requests WHERE user_id='$lease_author')")"
[[ "$cancel_state" == "cancelled" && "$request_exists" == "f" ]] || {
  echo "ERROR: expired unstarted request did not cancel cleanly"
  exit 1
}
echo "ok: cancellation and claim serialize; expired unstarted request is cancellable"


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
SELECT lease_token AS account_lease_token, lease_generation AS account_lease_generation
FROM public.claim_account_deletion_work_items(1) \gset
SELECT batch_status
FROM public.prepare_account_deletion_leased(
  '$author', :'account_lease_token'::uuid, :'account_lease_generation'::bigint
);
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


# Race 3: an in-flight illustration reference write wins the advisory path lock.
# It targets the same character being hard-deleted; deletion must wait, then
# enqueue the path only after the new illustration row is committed and cascaded.
asset_author="10000000-0000-4000-8000-000000000032"
asset_path_a="$asset_author/20000000-0000-4000-8000-000000000032/30000000-0000-4000-8000-000000000038.jpg"
cat > "$tmpdir/asset-reattach-first.sql" <<SQL
BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.sub', '$asset_author', true);
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claims', '{"sub":"$asset_author","role":"service_role"}', true);
INSERT INTO public.character_illustrations (
  id, character_id, author_id, storage_path, asset_type, sort_order
) VALUES (
  '30000000-0000-4000-8000-000000000036',
  '20000000-0000-4000-8000-000000000032',
  '$asset_author', '$asset_path_a', 'gallery', 1
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
[[ "$asset_a_queued" == "t" && "$asset_a_referenced" == "f" ]] || {
  echo "ERROR: reattachment-first race did not preserve the live reference and enqueue cleanup"
  cat "$tmpdir/asset-reattach-first.log" "$tmpdir/asset-delete-after.log"
  exit 1
}
echo "ok: in-flight illustration write wins path lock; deletion waits then queues cascaded asset"

# Race 4: deletion owns the path lock first. A later attempt to attach that path
# must wait until the cleanup row is committed, then fail in the BEFORE trigger.
asset_path_b="$asset_author/20000000-0000-4000-8000-000000000034/30000000-0000-4000-8000-000000000034.jpg"
asset_video_path_b="$asset_author/20000000-0000-4000-8000-000000000034/avatar.mp4"
cat > "$tmpdir/asset-delete-first.sql" <<SQL
BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.sub', '$asset_author', true);
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claims', '{"sub":"$asset_author","role":"service_role"}', true);
SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('character-avatar-videos:' || '$asset_video_path_b', 0));
SELECT pg_sleep(2);
SELECT public.soft_delete_character('20000000-0000-4000-8000-000000000034');
COMMIT;
SQL
cat > "$tmpdir/asset-reattach-after-delete.sql" <<SQL
BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.sub', '$asset_author', true);
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT set_config('request.jwt.claims', '{"sub":"$asset_author","role":"service_role"}', true);
INSERT INTO public.characters (
  id, author_id, name, visibility, review_status, rights_confirmed, avatar_video_path
) VALUES (
  '20000000-0000-4000-8000-000000000034',
  '$asset_author', 'Attempted recreated character', 'private', 'draft', true,
  '$asset_video_path_b'
);
COMMIT;
SQL

PGAPPNAME=pr200-asset-delete-first psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/asset-delete-first.sql" >"$tmpdir/asset-delete-first.log" 2>&1 &
asset_delete_first_pid=$!
wait_for_activity "pr200-asset-delete-first" "pg_sleep(2)"
PGAPPNAME=pr200-asset-reattach-after psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/asset-reattach-after-delete.sql" >"$tmpdir/asset-reattach-after-delete.log" 2>&1 &
reattach_after_pid=$!
wait_for_lock "pr200-asset-reattach-after"
if wait "$reattach_after_pid"; then
  echo "ERROR: reattachment unexpectedly succeeded after cleanup path was queued"
  exit 1
fi
wait "$asset_delete_first_pid"
if ! grep -q "character_asset_path_cleanup_already_queued" "$tmpdir/asset-reattach-after-delete.log"; then
  echo "ERROR: queued asset path reattachment did not fail at the cleanup guard"
  cat "$tmpdir/asset-reattach-after-delete.log"
  exit 1
fi
asset_b_queued="$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM public.character_asset_cleanup_jobs WHERE bucket_id='character-avatar-videos' AND object_path='$asset_video_path_b')")"
asset_b_illustration_queued="$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM public.character_asset_cleanup_jobs WHERE bucket_id='character-illustrations' AND object_path='$asset_path_b')")"
asset_b_referenced="$(psql "$DATABASE_URL" -Atqc "SELECT EXISTS (SELECT 1 FROM public.characters WHERE id='20000000-0000-4000-8000-000000000034')")"
[[ "$asset_b_queued" == "t" && "$asset_b_illustration_queued" == "t" && "$asset_b_referenced" == "f" ]] || {
  echo "ERROR: delete-first race left an invalid queued/referenced path state"
  exit 1
}
echo "ok: deletion wins path lock; queued asset path cannot be reattached"

echo "Deletion concurrency tests: 4 passed, 0 failed"
