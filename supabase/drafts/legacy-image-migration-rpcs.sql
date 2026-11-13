-- Local/disposable integration-test RPCs for legacy image migration.
-- REVIEW DRAFT ONLY: do not apply to hosted Supabase without separate approval.
-- These functions are intentionally callable only by service_role.

create or replace function public.poyozz_migrate_legacy_chat_snapshot(
  p_session_id uuid,
  p_character_id uuid,
  p_expected_snapshot jsonb,
  p_next_snapshot jsonb
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.chat_sessions
     set character_snapshot = p_next_snapshot,
         updated_at = now()
   where id = p_session_id
     and character_id is not distinct from p_character_id
     and character_snapshot = p_expected_snapshot;
  return found;
end;
$$;

create or replace function public.poyozz_clear_legacy_character_avatar(
  p_character_id uuid,
  p_author_id uuid,
  p_expected_data_uri_sha256 text
) returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
begin
  update public.characters
     set avatar_url = null
   where id = p_character_id
     and author_id = p_author_id
     and avatar_url is not null
     and encode(extensions.digest(convert_to(avatar_url, 'UTF8'), 'sha256'), 'hex')
         = p_expected_data_uri_sha256;
  return found;
end;
$$;

revoke all on function public.poyozz_migrate_legacy_chat_snapshot(uuid, uuid, jsonb, jsonb)
  from public, anon, authenticated;
revoke all on function public.poyozz_clear_legacy_character_avatar(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.poyozz_migrate_legacy_chat_snapshot(uuid, uuid, jsonb, jsonb)
  to service_role;
grant execute on function public.poyozz_clear_legacy_character_avatar(uuid, uuid, text)
  to service_role;
