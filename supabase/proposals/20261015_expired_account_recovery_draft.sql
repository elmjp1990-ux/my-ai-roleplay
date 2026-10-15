-- PROPOSAL ONLY — do not apply to production yet.
-- Controlled recovery for an expired deletion request.
-- Requires disposable-project tests and review of the existing batch/status model first.

begin;

create table if not exists public.account_deletion_recovery_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  request_requested_at timestamptz,
  request_scheduled_for timestamptz,
  archive_batch_id uuid,
  actor_user_id uuid not null,
  outcome text not null check (outcome in ('recovered')),
  reason text not null default 'user_initiated_recovery',
  created_at timestamptz not null default statement_timestamp()
);

alter table public.account_deletion_recovery_events enable row level security;
revoke all on table public.account_deletion_recovery_events from public, anon, authenticated, service_role;
-- No client table access. Only the SECURITY DEFINER RPC writes audit events.

create or replace function public.recover_expired_account_deletion()
returns table(recovered boolean, result_code text)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_requested_at timestamptz;
  v_scheduled_for timestamptz;
  v_batch_id uuid;
  v_batch_status text;
  v_ai_source bigint;
  v_ai_archived bigint;
  v_wallet_source bigint;
  v_wallet_archived bigint;
  v_archived_batch_count bigint;
begin
  if v_user_id is null then
    raise exception '請先登入';
  end if;

  -- Lock the request so a concurrent recovery/worker cannot pass the same gate.
  select r.requested_at, r.scheduled_for
    into v_requested_at, v_scheduled_for
  from public.account_deletion_requests r
  where r.user_id = v_user_id
  for update;

  if not found then
    return query select false, 'no_request'::text;
    return;
  end if;

  -- A missing deadline is malformed state, not proof that the request expired.
  if v_scheduled_for is null then
    return query select false, 'manual_review_required'::text;
    return;
  end if;

  if v_scheduled_for > pg_catalog.statement_timestamp() then
    return query select false, 'use_cancel_before_deadline'::text;
    return;
  end if;

  -- Fail closed if any batch suggests processing has started or finished.
  -- Only archived batches (subject to full reconciliation) and empty cancelled
  -- batches are potentially eligible. Unknown and terminal states stop recovery.
  if exists (
    select 1
    from public.account_deletion_archive_batches b
    where b.target_user_id = v_user_id
      and (b.status is null or b.status not in ('archived', 'cancelled'))
  ) then
    return query select false, 'manual_review_required'::text;
    return;
  end if;

  -- A cancelled batch containing any archive item may represent partial work.
  -- Do not unlock the account until an operator reconciles that state.
  if exists (
    select 1
    from public.account_deletion_archive_batches b
    join public.account_deletion_archive_items i on i.batch_id = b.id
    where b.target_user_id = v_user_id
      and b.status = 'cancelled'
  ) then
    return query select false, 'manual_review_required'::text;
    return;
  end if;

  select count(*) into v_archived_batch_count
  from public.account_deletion_archive_batches b
  where b.target_user_id = v_user_id and b.status = 'archived';

  -- Multiple archived batches require an operator to reconcile every batch;
  -- do not assume the latest batch alone represents the full archive history.
  if v_archived_batch_count > 1 then
    return query select false, 'manual_review_required'::text;
    return;
  end if;

  -- Select the archived batch explicitly. A newer empty cancelled batch must not
  -- hide an older archived batch from the integrity check.
  select b.id, b.status
    into v_batch_id, v_batch_status
  from public.account_deletion_archive_batches b
  where b.target_user_id = v_user_id
    and b.status = 'archived'
  order by b.created_at desc
  limit 1
  for update;

  if v_archived_batch_count = 1 and v_batch_status = 'archived' then
    select count(*) into v_ai_source
    from public.ai_generation_records a where a.user_id = v_user_id;
    select count(*) into v_ai_archived
    from public.account_deletion_archive_items i
    where i.batch_id = v_batch_id and i.source_table = 'ai_generation_records';

    select count(*) into v_wallet_source
    from public.wallet_transactions w where w.user_id = v_user_id;
    select count(*) into v_wallet_archived
    from public.account_deletion_archive_items i
    where i.batch_id = v_batch_id and i.source_table = 'wallet_transactions';

    if v_ai_source <> v_ai_archived or v_wallet_source <> v_wallet_archived then
      return query select false, 'archive_count_mismatch'::text;
      return;
    end if;

    if exists (
      select 1
      from public.ai_generation_records a
      left join public.account_deletion_archive_items i
        on i.batch_id = v_batch_id
       and i.source_table = 'ai_generation_records'
       and i.source_record_id = a.id::text
      where a.user_id = v_user_id
        and (i.id is null or i.payload is distinct from pg_catalog.to_jsonb(a))
    ) or exists (
      select 1
      from public.wallet_transactions w
      left join public.account_deletion_archive_items i
        on i.batch_id = v_batch_id
       and i.source_table = 'wallet_transactions'
       and i.source_record_id = w.id::text
      where w.user_id = v_user_id
        and (i.id is null or i.payload is distinct from pg_catalog.to_jsonb(w))
    ) then
      return query select false, 'archive_payload_mismatch'::text;
      return;
    end if;
  end if;

  -- Append the audit event and unblock the account atomically.
  insert into public.account_deletion_recovery_events
    (user_id, request_requested_at, request_scheduled_for,
     archive_batch_id, actor_user_id, outcome, reason)
  values
    (v_user_id, v_requested_at, v_scheduled_for,
     v_batch_id, v_user_id, 'recovered', 'user_initiated_recovery');

  delete from public.account_deletion_requests r
  where r.user_id = v_user_id;

  return query select true, 'recovered'::text;
end;
$function$;

revoke all on function public.recover_expired_account_deletion() from public, anon;
grant execute on function public.recover_expired_account_deletion() to authenticated;

commit;

-- Important pre-application review items:
-- 1. Confirm actual table column types, PKs, FK requirements, and enum/status constraints.
-- 2. Verify a NULL scheduled_for fails closed as manual_review_required.
-- 3. Decide whether repeated calls after successful recovery should return a distinct idempotent success; this draft currently returns no_request.
-- 4. Test row-lock coordination against the real worker before any worker is enabled.
-- 5. Validate every archived batch row and status transition; this draft fails closed for multiple archived batches and cancelled batches with residual items.
-- 6. Verify source-table row visibility under SECURITY DEFINER and exact archive payload schema.
-- 7. Confirm the product/legal retention policy and whether audit events need FK/retention constraints.
-- 8. Do not apply to production until reviewed and explicitly approved.
