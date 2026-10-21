alter table public.chat_group_messages
  add column if not exists deleted_at timestamptz;

grant update (content, deleted_at) on table public.chat_group_messages to authenticated;
