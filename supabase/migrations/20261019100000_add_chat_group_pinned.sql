-- Persist each group owner's pin state in Supabase so it follows their account across devices.
alter table public.chat_groups
  add column if not exists pinned boolean not null default false;

comment on column public.chat_groups.pinned is
  'Whether the owning user has pinned this group in their chat list.';
