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

create or replace function public.get_story_world_state(p_session_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_state public.story_world_states%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select user_id into v_user_id
  from public.chat_sessions
  where id = p_session_id and deleted_at is null;

  if v_user_id is null or v_user_id <> auth.uid() then
    raise exception 'story_session_not_owned' using errcode = '42501';
  end if;

  select * into v_state
  from public.story_world_states
  where session_id = p_session_id;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'storyTime', v_state.story_time,
    'storyLocation', v_state.story_location,
    'updatedAt', v_state.updated_at
  );
end;
$$;

create or replace function public.upsert_story_world_state(
  p_session_id uuid,
  p_story_time text,
  p_story_location text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_state public.story_world_states%rowtype;
begin
  if auth.role() <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;

  if nullif(btrim(p_story_time), '') is null or char_length(p_story_time) > 80
     or nullif(btrim(p_story_location), '') is null or char_length(p_story_location) > 120 then
    raise exception 'invalid_story_world_state' using errcode = '22023';
  end if;

  insert into public.story_world_states (session_id, story_time, story_location, updated_at)
  values (p_session_id, btrim(p_story_time), btrim(p_story_location), now())
  on conflict (session_id) do update
    set story_time = excluded.story_time,
        story_location = excluded.story_location,
        updated_at = now()
  returning * into v_state;

  return jsonb_build_object(
    'storyTime', v_state.story_time,
    'storyLocation', v_state.story_location,
    'updatedAt', v_state.updated_at
  );
end;
$$;

revoke all on function public.get_story_world_state(uuid) from public, anon;
grant execute on function public.get_story_world_state(uuid) to authenticated;
revoke all on function public.upsert_story_world_state(uuid, text, text) from public, anon, authenticated;
grant execute on function public.upsert_story_world_state(uuid, text, text) to service_role;

revoke all on table public.story_world_states from anon, authenticated;
grant all on table public.story_world_states to service_role;
