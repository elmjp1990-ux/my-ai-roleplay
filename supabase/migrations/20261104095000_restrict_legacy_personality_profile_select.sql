-- Restrict public character reads to explicitly approved columns.
-- The legacy personality_profile column remains for old-client compatibility,
-- but it must not be readable by anon/authenticated while the migration window is open.
begin;

-- Remove both table-wide and column-specific grants. A prior explicit column
-- grant survives a table-level REVOKE, so revoke the legacy private column too.
revoke select on table public.characters from public, anon, authenticated;
revoke select (personality_profile) on table public.characters from public, anon, authenticated;

grant select (
  id,
  author_id,
  name,
  title,
  gender,
  age,
  avatar_url,
  visibility,
  review_status,
  created_at,
  intro,
  race,
  style,
  tags,
  first_published_at,
  latest_eligible,
  rights_confirmed,
  deleted_at,
  deletion_reason,
  phone_settings,
  nsfw_workplace_warning,
  is_nsfw,
  avatar_video_path
) on table public.characters to anon, authenticated;

comment on column public.characters.personality_profile is
  'Legacy compatibility column. SELECT is revoked from PUBLIC, anon, and authenticated; authoritative author-only data lives in character_private_info.';

commit;
