-- Track per-request model usage and idempotent five-player-turn memory summaries.
begin;
create table if not exists public.ai_model_usage (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  turn_id uuid references public.chat_turn_charges(turn_id) on delete set null,
  assistant_message_id uuid references public.chat_messages(id) on delete set null,
  generation_type text not null check (generation_type in ('chat_response', 'memory_summary')),
  batch_number integer,
  source_turn_ids uuid[] not null default '{}'::uuid[],
  model text not null check (char_length(model) between 1 and 128),
  provider text check (provider is null or char_length(provider) <= 100),
  gateway_request_id text check (gateway_request_id is null or char_length(gateway_request_id) <= 128),
  prompt_tokens integer check (prompt_tokens is null or prompt_tokens >= 0),
  completion_tokens integer check (completion_tokens is null or completion_tokens >= 0),
  total_tokens integer check (total_tokens is null or total_tokens >= 0),
  cost_usd numeric(20,12) check (cost_usd is null or cost_usd >= 0),
  status text not null check (status in ('processing', 'completed', 'failed')),
  summary text check (summary is null or char_length(summary) <= 1000),
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  constraint ai_model_usage_generation_fields_check check (
    (generation_type = 'chat_response' and turn_id is not null and assistant_message_id is not null
      and batch_number is null and cardinality(source_turn_ids) = 0 and summary is null)
    or
    (generation_type = 'memory_summary' and turn_id is null and assistant_message_id is null
      and batch_number is not null and batch_number > 0 and cardinality(source_turn_ids) between 1 and 5)
  ),
  constraint ai_model_usage_completed_summary_check check (
    generation_type <> 'memory_summary' or status <> 'completed'
    or (summary is not null and processed_at is not null)
  )
);
create unique index if not exists ai_model_usage_chat_assistant_unique
  on public.ai_model_usage (assistant_message_id)
  where generation_type = 'chat_response' and assistant_message_id is not null;
create unique index if not exists ai_model_usage_summary_batch_unique
  on public.ai_model_usage (session_id, batch_number)
  where generation_type = 'memory_summary';
create index if not exists ai_model_usage_owner_session_created_idx
  on public.ai_model_usage (user_id, session_id, created_at desc);
alter table public.ai_model_usage enable row level security;
revoke all on table public.ai_model_usage from public, anon, authenticated;
grant select, insert, update on table public.ai_model_usage to service_role;
comment on table public.ai_model_usage is
  'Service-role-only usage ledger for POYOZZ chat generations and five-turn Story memory summaries. Stores token counts, provider cost and summary text, never prompts or raw conversation transcripts.';
commit;