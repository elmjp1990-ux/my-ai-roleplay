-- Move AI-only creator personality instructions out of publicly readable characters rows.
-- Phase 1 (expand): apply before deploying the matching frontend/backend code.
-- Keep the legacy public column temporarily for old app versions. Drop it in a
-- separate contract migration only after the new frontend and Edge Function are deployed.
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

-- Phase 2 is intentionally separate: drop the legacy public column only
-- after the new frontend and Edge Function no longer select it.
commit;
