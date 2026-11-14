#!/usr/bin/env bash
set -euo pipefail

: "\${DATABASE_URL:?DATABASE_URL is required}"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -At -c "SELECT 1" >/dev/null

# Different groups, same wallet: row locking must allow exactly one 3-credit
# reservation when the shared wallet contains only 5 silver coins.
set +e
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -At -c "SET ROLE service_role; SELECT turn_id FROM public.reserve_group_chat_turn('10000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000005','40000000-0000-4000-8000-000000000005','race group A');" >/tmp/group-race-a.log 2>&1 &
pid_a=$!
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -At -c "SET ROLE service_role; SELECT turn_id FROM public.reserve_group_chat_turn('10000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000006','40000000-0000-4000-8000-000000000006','race group B');" >/tmp/group-race-b.log 2>&1 &
pid_b=$!
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e

if [[ "$status_a" -eq 0 && "$status_b" -eq 0 ]] || [[ "$status_a" -ne 0 && "$status_b" -ne 0 ]]; then
  echo "Expected exactly one wallet reservation to succeed." >&2
  cat /tmp/group-race-a.log /tmp/group-race-b.log >&2
  exit 1
fi
if [[ "$status_a" -ne 0 ]] && ! grep -q "group_insufficient_funds" /tmp/group-race-a.log; then
  cat /tmp/group-race-a.log >&2; exit 1
fi
if [[ "$status_b" -ne 0 ]] && ! grep -q "group_insufficient_funds" /tmp/group-race-b.log; then
  cat /tmp/group-race-b.log >&2; exit 1
fi

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -At <<'SQL'
DO $$
DECLARE n integer; balance integer;
BEGIN
  SELECT count(*) INTO n FROM public.chat_group_turns
  WHERE user_id='10000000-0000-4000-8000-000000000005' AND status='processing';
  IF n <> 1 THEN RAISE EXCEPTION 'wallet race created % successful turns, expected 1', n; END IF;
  SELECT silver_coins INTO balance FROM public.wallet_accounts
  WHERE user_id='10000000-0000-4000-8000-000000000005';
  IF balance <> 2 THEN RAISE EXCEPTION 'wallet race left balance %, expected 2', balance; END IF;
END
$$;
SQL

# Same group + same request key in parallel must return one shared turn and
# create only one charge/ledger operation.
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -At -c "SET ROLE service_role; SELECT turn_id FROM public.reserve_group_chat_turn('10000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000007','40000000-0000-4000-8000-000000000007','same request');" >/tmp/group-idem-a.log 2>&1 &
pid_a=$!
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -At -c "SET ROLE service_role; SELECT turn_id FROM public.reserve_group_chat_turn('10000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000007','40000000-0000-4000-8000-000000000007','same request');" >/tmp/group-idem-b.log 2>&1 &
pid_b=$!
wait "$pid_a"
wait "$pid_b"

turn_a="$(grep -Eo '[0-9a-f]{8}-[0-9a-f-]{27,}' /tmp/group-idem-a.log | tail -n 1)"
turn_b="$(grep -Eo '[0-9a-f]{8}-[0-9a-f-]{27,}' /tmp/group-idem-b.log | tail -n 1)"
if [[ -z "$turn_a" || "$turn_a" != "$turn_b" ]]; then
  echo "Concurrent idempotent requests did not return the same turn." >&2
  cat /tmp/group-idem-a.log /tmp/group-idem-b.log >&2
  exit 1
fi

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -At <<'SQL'
DO $$
DECLARE n integer; balance integer;
BEGIN
  SELECT count(*) INTO n FROM public.chat_group_turn_charges
  WHERE group_id='20000000-0000-4000-8000-000000000007';
  IF n <> 1 THEN RAISE EXCEPTION 'idempotent race created % charges', n; END IF;
  SELECT silver_coins INTO balance FROM public.wallet_accounts
  WHERE user_id='10000000-0000-4000-8000-000000000006';
  IF balance <> 7 THEN RAISE EXCEPTION 'idempotent race charged more than once: balance %', balance; END IF;
END
$$;
SQL

echo "Concurrent group transaction tests passed."
