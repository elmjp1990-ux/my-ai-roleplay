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

author="10000000-0000-4000-8000-000000000038"
player="10000000-0000-4000-8000-000000000031"
character="20000000-0000-4000-8000-000000000038"

# Four isolated parent-lock races cover single chats and groups. The dedicated
# snapshot author/character fixture is not used by the base deletion suite.

solo_sync_first="50000000-0000-4000-8000-000000000041"
solo_delete_first="50000000-0000-4000-8000-000000000042"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<SQL
INSERT INTO public.chat_sessions (
  id, user_id, character_id, character_name, chat_mode, character_snapshot
) VALUES
  ('$solo_sync_first', '$player', '$character', 'Snapshot race character A', 'story', '{"marker":"solo-sync-first"}'::jsonb),
  ('$solo_delete_first', '$player', '$character', 'Snapshot race character A', 'story', '{"marker":"solo-delete-first"}'::jsonb);
SQL

# Sync wins: the service role holds the exact parent row; the authenticated
# author claim is retained for the SECURITY DEFINER snapshot RPC.
cat > "$tmpdir/solo-sync-wins.sql" <<SQL
BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.sub', '$author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$author","role":"authenticated"}', true);
SELECT id FROM public.chat_sessions WHERE id='$solo_sync_first' FOR UPDATE;
SELECT pg_sleep(2);
SELECT public.sync_character_chat_snapshot('$character');
COMMIT;
SQL
cat > "$tmpdir/solo-delete-loses.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$player', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$player","role":"authenticated"}', true);
SELECT public.delete_chat_session_content('$solo_sync_first');
COMMIT;
SQL
PGAPPNAME=pr200-solo-sync-wins psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/solo-sync-wins.sql" >"$tmpdir/solo-sync-wins.log" 2>&1 &
solo_sync_pid=$!
wait_for_activity "pr200-solo-sync-wins" "pg_sleep(2)"
PGAPPNAME=pr200-solo-delete-loses psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/solo-delete-loses.sql" >"$tmpdir/solo-delete-loses.log" 2>&1 &
solo_delete_pid=$!
wait_for_lock "pr200-solo-delete-loses"
wait "$solo_sync_pid"
wait "$solo_delete_pid"
psql "$DATABASE_URL" -Atq >"$tmpdir/solo-sync-state.txt" <<SQL
SELECT deleted_at IS NOT NULL AND character_snapshot->>'visibility'='public'
FROM public.chat_sessions WHERE id='$solo_sync_first';
SQL
solo_sync_state="$(tr -d '\r\n' < "$tmpdir/solo-sync-state.txt")"
[[ "$solo_sync_state" == "t" ]] || {
  echo "ERROR: solo snapshot sync did not commit before chat deletion"
  cat "$tmpdir/solo-sync-wins.log" "$tmpdir/solo-delete-loses.log"
  exit 1
}
echo "ok: solo snapshot sync wins the parent lock before chat deletion"

# Delete wins: the author's sync RPC must wait, then exclude the soft-deleted
# parent so the original snapshot remains frozen.
cat > "$tmpdir/solo-delete-wins.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$player', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$player","role":"authenticated"}', true);
SELECT id FROM public.chat_sessions WHERE id='$solo_delete_first' FOR UPDATE;
SELECT pg_sleep(2);
SELECT public.delete_chat_session_content('$solo_delete_first');
COMMIT;
SQL
cat > "$tmpdir/solo-sync-loses.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$author","role":"authenticated"}', true);
SELECT public.sync_character_chat_snapshot('$character');
COMMIT;
SQL
PGAPPNAME=pr200-solo-delete-wins psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/solo-delete-wins.sql" >"$tmpdir/solo-delete-wins.log" 2>&1 &
solo_delete_wins_pid=$!
wait_for_activity "pr200-solo-delete-wins" "pg_sleep(2)"
PGAPPNAME=pr200-solo-sync-loses psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/solo-sync-loses.sql" >"$tmpdir/solo-sync-loses.log" 2>&1 &
solo_sync_loses_pid=$!
wait_for_lock "pr200-solo-sync-loses"
wait "$solo_delete_wins_pid"
wait "$solo_sync_loses_pid"
psql "$DATABASE_URL" -Atq >"$tmpdir/solo-delete-state.txt" <<SQL
SELECT deleted_at IS NOT NULL
  AND character_snapshot->>'marker'='solo-delete-first'
  AND NOT (character_snapshot ? 'visibility')
FROM public.chat_sessions WHERE id='$solo_delete_first';
SQL
solo_delete_state="$(tr -d '\r\n' < "$tmpdir/solo-delete-state.txt")"
[[ "$solo_delete_state" == "t" ]] || {
  echo "ERROR: solo snapshot sync modified a deleted parent's frozen snapshot"
  cat "$tmpdir/solo-delete-wins.log" "$tmpdir/solo-sync-loses.log"
  exit 1
}
echo "ok: solo chat deletion wins the parent lock and freezes its snapshot"

# Group parent fixtures are created only after solo tests so the solo sync does
# not update them as collateral rows.
group_sync_first="50000000-0000-4000-8000-000000000043"
group_delete_first="50000000-0000-4000-8000-000000000044"
member_sync_first="60000000-0000-4000-8000-000000000043"
member_delete_first="60000000-0000-4000-8000-000000000044"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<SQL
INSERT INTO public.chat_groups (id, owner_id, name, scene_mode)
VALUES
  ('$group_sync_first', '$player', 'Snapshot Sync Group', 'shared'),
  ('$group_delete_first', '$player', 'Snapshot Delete Group', 'shared');
INSERT INTO public.chat_group_members (id, group_id, character_id, position, character_snapshot)
VALUES
  ('$member_sync_first', '$group_sync_first', '$character', 1, '{"marker":"group-sync-first"}'::jsonb),
  ('$member_delete_first', '$group_delete_first', '$character', 1, '{"marker":"group-delete-first"}'::jsonb);
SQL

cat > "$tmpdir/group-sync-wins.sql" <<SQL
BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.sub', '$author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$author","role":"authenticated"}', true);
SELECT id FROM public.chat_groups WHERE id='$group_sync_first' FOR UPDATE;
SELECT pg_sleep(2);
SELECT public.sync_character_chat_snapshot('$character');
COMMIT;
SQL
cat > "$tmpdir/group-delete-loses.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$player', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$player","role":"authenticated"}', true);
SELECT public.delete_chat_group_with_related_data('$group_sync_first');
COMMIT;
SQL
PGAPPNAME=pr200-group-sync-wins psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/group-sync-wins.sql" >"$tmpdir/group-sync-wins.log" 2>&1 &
group_sync_pid=$!
wait_for_activity "pr200-group-sync-wins" "pg_sleep(2)"
PGAPPNAME=pr200-group-delete-loses psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/group-delete-loses.sql" >"$tmpdir/group-delete-loses.log" 2>&1 &
group_delete_pid=$!
wait_for_lock "pr200-group-delete-loses"
wait "$group_sync_pid"
wait "$group_delete_pid"
psql "$DATABASE_URL" -Atq >"$tmpdir/group-sync-state.txt" <<SQL
SELECT g.deleted_at IS NOT NULL AND m.character_snapshot->>'visibility'='public'
FROM public.chat_groups g
JOIN public.chat_group_members m ON m.group_id=g.id
WHERE g.id='$group_sync_first' AND m.id='$member_sync_first';
SQL
group_sync_state="$(tr -d '\r\n' < "$tmpdir/group-sync-state.txt")"
[[ "$group_sync_state" == "t" ]] || {
  echo "ERROR: group snapshot sync did not commit before group deletion"
  cat "$tmpdir/group-sync-wins.log" "$tmpdir/group-delete-loses.log"
  exit 1
}
echo "ok: group snapshot sync wins the parent lock before group deletion"

# Delete wins for a group: sync must re-check group.deleted_at after acquiring
# the parent lock and leave the member snapshot byte-for-byte unchanged.
cat > "$tmpdir/group-delete-wins.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$player', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$player","role":"authenticated"}', true);
SELECT id FROM public.chat_groups WHERE id='$group_delete_first' FOR UPDATE;
SELECT pg_sleep(2);
SELECT public.delete_chat_group_with_related_data('$group_delete_first');
COMMIT;
SQL
cat > "$tmpdir/group-sync-loses.sql" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$author', true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claims', '{"sub":"$author","role":"authenticated"}', true);
SELECT public.sync_character_chat_snapshot('$character');
COMMIT;
SQL
PGAPPNAME=pr200-group-delete-wins psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/group-delete-wins.sql" >"$tmpdir/group-delete-wins.log" 2>&1 &
group_delete_wins_pid=$!
wait_for_activity "pr200-group-delete-wins" "pg_sleep(2)"
PGAPPNAME=pr200-group-sync-loses psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmpdir/group-sync-loses.sql" >"$tmpdir/group-sync-loses.log" 2>&1 &
group_sync_loses_pid=$!
wait_for_lock "pr200-group-sync-loses"
wait "$group_delete_wins_pid"
wait "$group_sync_loses_pid"
psql "$DATABASE_URL" -Atq >"$tmpdir/group-delete-state.txt" <<SQL
SELECT g.deleted_at IS NOT NULL
  AND m.character_snapshot->>'marker'='group-delete-first'
  AND NOT (m.character_snapshot ? 'visibility')
FROM public.chat_groups g
JOIN public.chat_group_members m ON m.group_id=g.id
WHERE g.id='$group_delete_first' AND m.id='$member_delete_first';
SQL
group_delete_state="$(tr -d '\r\n' < "$tmpdir/group-delete-state.txt")"
[[ "$group_delete_state" == "t" ]] || {
  echo "ERROR: group snapshot sync modified a deleted group's frozen member snapshot"
  cat "$tmpdir/group-delete-wins.log" "$tmpdir/group-sync-loses.log"
  exit 1
}
echo "ok: group deletion wins the parent lock and freezes member snapshots"

echo "Character chat snapshot race tests: 4 passed, 0 failed"
