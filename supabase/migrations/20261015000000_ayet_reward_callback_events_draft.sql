-- DRAFT ONLY — do not run against production without review/approval.
-- Dedicated immutable idempotency ledger for verified ayeT rewarded-video events.
-- Exact event fields and uniqueness key must match ayeT's confirmed callback contract.
create table if not exists public.ayet_reward_callback_events (
  id uuid primary key default gen_random_uuid(),
  provider_transaction_id text not null,
  user_id uuid not null references auth.users(id) on delete restrict,
  adslot_type text not null check (adslot_type = 'rewarded_video'),
  event_status text not null check (event_status in ('verified', 'credited', 'rejected')),
  reward_amount integer not null check (reward_amount > 0),
  received_at timestamptz not null default now(),
  credited_at timestamptz,
  provider_payload jsonb not null default '{}'::jsonb,
  constraint ayet_reward_callback_events_provider_transaction_id_key unique (provider_transaction_id)
);

alter table public.ayet_reward_callback_events enable row level security;
-- No client-facing policies: only trusted server-side code should access this table.
revoke all on public.ayet_reward_callback_events from anon, authenticated;
