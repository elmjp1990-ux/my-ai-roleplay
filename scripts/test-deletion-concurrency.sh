#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required}"
tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

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

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/delete-owner.sql" >"$tmpdir/delete-owner.log" 2>&1 &
delete_pid=$!
sleep 0.4
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

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/child-writer.sql" >"$tmpdir/child-writer.log" 2>&1 &
child_pid=$!
sleep 0.4
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/account-archive.sql" >"$tmpdir/account-archive.log" 2>&1 &
archive_pid=$!
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

echo "Deletion concurrency tests: 2 passed, 0 failed"
