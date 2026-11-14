#!/usr/bin/env bash
set -euo pipefail

: "\${DATABASE_URL:?DATABASE_URL is required}"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -At -c "SELECT 1" >/dev/null


# Completion racing the watchdog on an already-expired turn: the deadline
# check must prevent late persistence whichever transaction obtains the lock.
turn_race="$(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -qAt -c "SET ROLE service_role; SELECT turn_id FROM public.reserve_group_chat_turn('10000000-0000-4000-8000-000000000007','20000000-0000-4000-8000-000000000008','40000000-0000-4000-8000-000000000008','completion vs watchdog');")"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -c "UPDATE public.chat_group_turns SET processing_started_at=clock_timestamp()-interval '60 seconds' WHERE id='$turn_race';" >/dev/null

set +e
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -c "SET ROLE service_role; SELECT public.complete_group_chat_turn('10000000-0000-4000-8000-000000000007','$turn_race','[{\"speaker_id\":\"30000000-0000-4000-8000-000000000009\",\"content\":\"late reply must not persist\"}]'::jsonb);" >/tmp/group-complete-race.log 2>&1 &
pid_complete=$!
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -c "SET ROLE service_role; SELECT * FROM public.expire_group_chat_turn('10000000-0000-4000-8000-000000000007','$turn_race');" >/tmp/group-expire-race.log 2>&1 &
pid_expire=$!
wait "$pid_complete"; complete_status=$?
wait "$pid_expire"; expire_status=$?
set -e

if [[ "$complete_status" -eq 0 || "$expire_status" -ne 0 ]]; then
  echo "Expected the overdue completion to lose and the watchdog refund to succeed." >&2
  cat /tmp/group-complete-race.log /tmp/group-expire-race.log >&2
  exit 1
fi
if ! grep -Eq "group_turn_deadline_exceeded|group_turn_not_completable" /tmp/group-complete-race.log; then
  cat /tmp/group-complete-race.log >&2; exit 1
fi
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X <<SQL
DO \$\$
DECLARE n integer;
BEGIN
  IF (SELECT status FROM public.chat_group_turns WHERE id='$turn_race') <> 'failed'
    OR (SELECT status FROM public.chat_group_turn_charges WHERE group_turn_id='$turn_race') <> 'refunded' THEN
    RAISE EXCEPTION 'completion/watchdog race did not end in one refunded terminal state';
  END IF;
  SELECT count(*) INTO n FROM public.chat_group_messages
  WHERE turn_id='$turn_race' AND speaker_type='character';
  IF n <> 0 THEN RAISE EXCEPTION 'late AI reply persisted after timeout'; END IF;
  SELECT count(*) INTO n FROM public.wallet_transactions
  WHERE reference_id='$turn_race' AND biz_type='group_chat_turn_refund';
  IF n <> 1 THEN RAISE EXCEPTION 'completion/watchdog race created % refund ledger rows', n; END IF;
END
\$\$;
SQL

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
