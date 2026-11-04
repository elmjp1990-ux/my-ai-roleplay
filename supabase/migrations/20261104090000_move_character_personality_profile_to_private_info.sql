-- Move AI-only creator personality instructions out of publicly readable characters rows.
-- Apply only after the matching frontend/backend code is deployed.
begin;

alter table public.character_private_info
  add column if not exists personality_profile jsonb not null default '{}'::jsonb;

insert into public.character_private_info (
  character_id,
  author_id,
  private_info,
  personality_profile
)
select
  c.id,
  c.author_id,
  '',
  coalesce(c.personality_profile, '{}'::jsonb)
from public.characters c
where coalesce(c.personality_profile, '{}'::jsonb) <> '{}'::jsonb
on conflict (character_id) do update
set personality_profile = case
  when coalesce(public.character_private_info.personality_profile, '{}'::jsonb) = '{}'::jsonb
    then excluded.personality_profile
  else public.character_private_info.personality_profile
end;

-- Remove the publicly selectable column after all existing values are preserved
-- in the author-only table governed by its existing owner RLS policy.
alter table public.characters
  drop column if exists personality_profile;

commit;
