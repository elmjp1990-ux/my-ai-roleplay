-- Persist contextual Story time and location independently from the chat session row.
-- The AI updates this state as part of the already-billed Story turn; no extra model call is made.
create table if not exists public.story_world_states (
  session_id uuid primary key references public.chat_sessions(id) on delete cascade,
  story_time text not null,
  story_location text not null,
  updated_at timestamptz not null default now(),
  constraint story_world_states_time_length check (char_length(story_time) between 1 and 80),
  constraint story_world_states_location_length check (char_length(story_location) between 1 and 120)
);

alter table public.story_world_states enable row level security;
revoke all on table public.story_world_states from anon, authenticated;
grant select on table public.story_world_states to authenticated;
grant all on table public.story_world_states to service_role;

create policy "Story owners can read their world state"
on public.story_world_states
for select
to authenticated
using (
  exists (
    select 1
    from public.chat_sessions s
    where s.id = story_world_states.session_id
      and s.user_id = (select auth.uid())
      and s.deleted_at is null
  )
);

create or replace function public.get_story_world_state(p_session_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'storyTime', story_time,
    'storyLocation', story_location,
    'updatedAt', updated_at
  )
  from public.story_world_states
  where session_id = p_session_id;
$$;

revoke all on function public.get_story_world_state(uuid) from public, anon;
grant execute on function public.get_story_world_state(uuid) to authenticated;
