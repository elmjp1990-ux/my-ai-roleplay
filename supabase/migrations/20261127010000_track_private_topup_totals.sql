-- Track lifetime top-up totals privately for shop member tiers.
create table if not exists public.user_topup_totals (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  total_twd bigint not null default 0 check (total_twd >= 0),
  updated_at timestamptz not null default now()
);
alter table public.user_topup_totals enable row level security;
revoke all on table public.user_topup_totals from public, anon, authenticated;
grant select on table public.user_topup_totals to authenticated;
drop policy if exists user_topup_totals_read_own on public.user_topup_totals;
create policy user_topup_totals_read_own
  on public.user_topup_totals for select to authenticated
  using (user_id = auth.uid());

-- Backfill historical TEST simulated package buys; bonus diamonds are not charged separately.
insert into public.user_topup_totals(user_id,total_twd,updated_at)
select user_id,sum(price_twd)::bigint,now()
from public.diamond_test_purchase_requests
group by user_id
on conflict (user_id) do update
set total_twd=excluded.total_twd,updated_at=now();

create or replace function public.add_test_purchase_to_topup_total()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  insert into public.user_topup_totals(user_id,total_twd,updated_at)
  values(new.user_id,new.price_twd,now())
  on conflict(user_id) do update
  set total_twd=public.user_topup_totals.total_twd+excluded.total_twd,
      updated_at=now();
  return new;
end;
$$;
revoke all on function public.add_test_purchase_to_topup_total() from public,anon,authenticated;

drop trigger if exists diamond_test_purchase_total_twd on public.diamond_test_purchase_requests;
create trigger diamond_test_purchase_total_twd
after insert on public.diamond_test_purchase_requests
for each row execute function public.add_test_purchase_to_topup_total();
