-- Source-only reconciliation draft for the fixed demo chat-turn handler.
-- NOT applied to production. Review and test in an isolated project first.
--
-- This is safe only while chat-turn returns a deterministic local demo reply and
-- has no external AI/provider job that can finish later. Do not schedule this
-- once a real provider is integrated until provider/job state is queried first.
--
-- For a stale turn, the refund RPC rechecks for a durable non-empty assistant
-- message and locks the charge row. The assistant INSERT trigger takes the same
-- lock and rejects a late reply after refund, closing the late-write race.

create or replace function public.reconcile_stale_demo_chat_turns(
  p_stale_minutes integer default 10,
  p_batch_size integer default 100
)
returns table(processed integer, settled_count integer, refunded_count integer, failed_count integer)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_charge public.chat_turn_charges%rowtype;
  v_processed integer := 0;
  v_settled integer := 0;
  v_refunded integer := 0;
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

  for v_charge in
    select c.*
    from public.chat_turn_charges c
    where c.status in ('reserved', 'needs_reconciliation')
      and c.updated_at < now() - make_interval(mins => p_stale_minutes)
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
        -- A stored assistant row is not enough to prove which turn generated it.
        -- Require the durable generation record to match every turn identifier
        -- before settling; otherwise leave the reservation for manual/retry reconciliation.
        if exists (
          select 1
          from public.ai_generation_records g
          where g.user_id = v_charge.user_id
            and g.session_id = v_charge.session_id
            and g.user_message_id = v_charge.user_message_id
            and g.assistant_message_id = v_charge.expected_assistant_message_id
            and g.request_id = v_charge.turn_id
            and length(btrim(coalesce(g.original_content, ''))) > 0
        ) then
          v_result := public.settle_chat_turn(
            v_charge.user_id,
            v_charge.turn_id,
            v_charge.expected_assistant_message_id
          );
          if v_result = 'settled' then
            v_settled := v_settled + 1;
          end if;
        else
          update public.chat_turn_charges
          set status = 'needs_reconciliation',
              failure_code = 'assistant_reply_identity_unverified',
              updated_at = now()
          where turn_id = v_charge.turn_id
            and user_id = v_charge.user_id
            and status in ('reserved', 'needs_reconciliation');
          insert into public.chat_turn_events(
            turn_id, user_id, event_type, stage, error_code
          ) values (
            v_charge.turn_id, v_charge.user_id, 'needs_reconciliation',
            'stale_demo_reconciliation', 'assistant_reply_identity_unverified'
          );
          v_failed := v_failed + 1;
        end if;
      else
        perform public.refund_chat_turn(
          v_charge.user_id,
          v_charge.turn_id,
          v_charge.expected_assistant_message_id,
          'stale_demo_turn_without_durable_reply'
        );
        v_refunded := v_refunded + 1;
      end if;
    exception when others then
      get stacked diagnostics v_sqlstate = returned_sqlstate;
      v_failed := v_failed + 1;
      insert into public.chat_turn_events(
        turn_id, user_id, event_type, stage, error_code
      ) values (
        v_charge.turn_id, v_charge.user_id, 'reconciliation_failed',
        'stale_demo_reconciliation', left('sqlstate_' || v_sqlstate, 80)
      );
    end;
  end loop;

  return query select v_processed, v_settled, v_refunded, v_failed;
end;
$function$;

revoke all on function public.reconcile_stale_demo_chat_turns(integer, integer) from public, anon, authenticated;
grant execute on function public.reconcile_stale_demo_chat_turns(integer, integer) to service_role;
