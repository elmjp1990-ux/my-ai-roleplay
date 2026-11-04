-- Safe reconciliation for Story turns with an unknown external provider outcome.
-- This function NEVER retries the provider and NEVER refunds an unknown outcome.
begin;

alter table public.chat_turn_charges
  add column if not exists reconciliation_checked_at timestamptz,
  add column if not exists reconciliation_attempts integer not null default 0;

alter table public.chat_turn_charges
  add constraint chat_turn_charges_reconciliation_attempts_nonnegative
  check (reconciliation_attempts >= 0) not valid;

alter table public.chat_turn_charges
  validate constraint chat_turn_charges_reconciliation_attempts_nonnegative;

create or replace function public.reconcile_stale_story_chat_turns(
  p_stale_minutes integer default 10,
  p_batch_size integer default 100,
  p_review_interval_minutes integer default 30
)
returns table(processed integer, settled_count integer, review_count integer, failed_count integer)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
  v_processed integer := 0;
  v_settled integer := 0;
  v_review integer := 0;
  v_failed integer := 0;
  v_result text;
  v_sqlstate text;
begin
  if p_stale_minutes is null or p_stale_minutes < 5 or p_stale_minutes > 1440 then
    raise exception 'invalid_stale_minutes';
  end if;
  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 500 then
    raise exception 'invalid_batch_size';
  end if;
  if p_review_interval_minutes is null or p_review_interval_minutes < 5 or p_review_interval_minutes > 1440 then
    raise exception 'invalid_review_interval';
  end if;

  for v_charge in
    select c.*
    from public.chat_turn_charges c
    where c.status = 'needs_reconciliation'
      and c.updated_at < now() - make_interval(mins => p_stale_minutes)
      and (
        c.reconciliation_checked_at is null
        or c.reconciliation_checked_at < now() - make_interval(mins => p_review_interval_minutes)
      )
    order by c.updated_at asc
    limit p_batch_size
    for update skip locked
  loop
    v_processed := v_processed + 1;
    begin
      if exists (
        select 1
        from public.chat_messages m
        where m.id = v_charge.expected_assistant_message_id
          and m.session_id = v_charge.session_id
          and m.role = 'assistant'
          and m.deleted_at is null
          and length(btrim(coalesce(m.content, ''))) > 0
      ) then
        v_result := public.settle_chat_turn(
          v_charge.user_id,
          v_charge.turn_id,
          v_charge.expected_assistant_message_id
        );
        if v_result = 'settled' then
          v_settled := v_settled + 1;
        else
          -- Fail closed if the settlement function ever returns an unexpected
          -- value: throttle repeated scans and require manual review.
          update public.chat_turn_charges c
          set reconciliation_checked_at = now(),
              reconciliation_attempts = c.reconciliation_attempts + 1
          where c.turn_id = v_charge.turn_id;

          insert into public.chat_turn_events(
            turn_id, user_id, event_type, stage, error_code
          ) values (
            v_charge.turn_id, v_charge.user_id, 'reconciliation_review_required',
            'stale_provider_outcome', 'unexpected_settlement_result_manual_review'
          );
          v_review := v_review + 1;
        end if;
      else
        -- Provider may still have completed upstream. Keep the charge locked:
        -- no automatic refund, no second provider call, no user-facing retry.
        update public.chat_turn_charges c
        set reconciliation_checked_at = now(),
            reconciliation_attempts = c.reconciliation_attempts + 1
        where c.turn_id = v_charge.turn_id;

        insert into public.chat_turn_events(
          turn_id, user_id, event_type, stage, error_code
        ) values (
          v_charge.turn_id, v_charge.user_id, 'reconciliation_review_required',
          'stale_provider_outcome', 'provider_outcome_unconfirmed_manual_review'
        );
        v_review := v_review + 1;
      end if;
    exception when others then
      get stacked diagnostics v_sqlstate = returned_sqlstate;
      update public.chat_turn_charges c
      set reconciliation_checked_at = now(),
          reconciliation_attempts = c.reconciliation_attempts + 1
      where c.turn_id = v_charge.turn_id;
      insert into public.chat_turn_events(
        turn_id, user_id, event_type, stage, error_code
      ) values (
        v_charge.turn_id, v_charge.user_id, 'reconciliation_failed',
        'stale_provider_reconciliation', left('sqlstate_' || v_sqlstate, 80)
      );
      v_failed := v_failed + 1;
    end;
  end loop;

  return query select v_processed, v_settled, v_review, v_failed;
end;
$function$;

revoke all on function public.reconcile_stale_story_chat_turns(integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.reconcile_stale_story_chat_turns(integer, integer, integer)
  to service_role;

comment on function public.reconcile_stale_story_chat_turns(integer, integer, integer) is
  'Service-role-only recovery: settles only an already durable assistant reply; unknown provider outcomes remain locked for manual review. Never retries or refunds an ambiguous provider request.';

commit;
