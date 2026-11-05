-- Preserve one usage row per provider attempt, including retries for the same chat turn.
begin;
drop index if exists public.ai_model_usage_chat_assistant_unique;
create index if not exists ai_model_usage_chat_assistant_idx
  on public.ai_model_usage (assistant_message_id, created_at desc)
  where generation_type = 'chat_response' and assistant_message_id is not null;
commit;
