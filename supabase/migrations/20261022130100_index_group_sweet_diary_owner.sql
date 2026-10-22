-- Support efficient owner-scoped foreign-key maintenance.
create index if not exists chat_group_diary_owner_id_idx on public.chat_group_diary(owner_id);
