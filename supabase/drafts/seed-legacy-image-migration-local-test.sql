-- Synthetic rows for disposable local legacy-image migration integration test.
-- No production or hosted data is referenced.

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data
) values (
  '10000000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', 'legacy-image-fixture@example.invalid',
  '', now(), now(), now(), '{}'::jsonb, '{}'::jsonb
) on conflict (id) do nothing;

-- A second authenticated user proves historical paths are not shared.
insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data
) values (
  '10000000-0000-4000-8000-000000000002',
  'authenticated', 'authenticated', 'legacy-image-outsider@example.invalid',
  '', now(), now(), now(), '{}'::jsonb, '{}'::jsonb
) on conflict (id) do nothing;

insert into public.profiles (id, handle, nickname)
values ('10000000-0000-4000-8000-000000000001', 'legacy-image-fixture', 'Fixture')
on conflict (id) do nothing;

insert into public.characters (id, author_id, name, avatar_url, visibility)
select
  ('20000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  '10000000-0000-4000-8000-000000000001'::uuid,
  'Legacy Fixture ' || n,
  'data:image/png;base64,' || encode(convert_to('current-primary-' || n, 'UTF8'), 'base64'),
  'private'
from generate_series(1, 8) n;

insert into public.chat_sessions (
  id, user_id, character_id, character_name, status,
  character_snapshot, session_data, chat_mode
)
select
  ('30000000-0000-4000-8000-' ||
    lpad((((right(c.id::text, 12)::integer - 1) * 10) + n)::text, 12, '0'))::uuid,
  '10000000-0000-4000-8000-000000000001'::uuid,
  c.id,
  c.name,
  'active',
  jsonb_build_object('id', c.id, 'name', c.name, 'image', c.avatar_url, 'opening', 'keep-current-opening'),
  '{}'::jsonb,
  'story'
from public.characters c
cross join lateral generate_series(
  1,
  case when right(c.id::text, 12)::integer <= 6 then 9 else 10 end
) n;

-- Historical versions deliberately use a different MIME casing so their bytes
-- parse as PNG but never compare equal to today's avatar_url string.
insert into public.chat_sessions (
  id, user_id, character_id, character_name, status,
  character_snapshot, session_data, chat_mode
)
select
  ('40000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
  '10000000-0000-4000-8000-000000000001'::uuid,
  c.id,
  c.name,
  'active',
  jsonb_build_object(
    'id', c.id, 'name', c.name,
    'image', 'data:image/PNG;base64,' || encode(convert_to('historical-version-' || n, 'UTF8'), 'base64'),
    'opening', 'keep-historical-opening'
  ),
  '{}'::jsonb,
  'story'
from generate_series(1, 13) n
join public.characters c
  on right(c.id::text, 12)::integer = ((n - 1) % 8) + 1;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'character-illustrations',
  'character-illustrations',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;


-- An object with a valid-looking owner/character path but no metadata
-- or chat-snapshot reference must remain unreadable.
insert into storage.objects (bucket_id, name)
values (
  'character-illustrations',
  '10000000-0000-4000-8000-000000000001/20000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000099.png'
)
on conflict (bucket_id, name) do nothing;

-- A deleted chat is retained by the application for its retention window,
-- but it must not be migrated into a readable private Storage snapshot path.
insert into public.chat_sessions (
  id, user_id, character_id, character_name, status,
  character_snapshot, session_data, chat_mode, deleted_at
)
select
  '50000000-0000-4000-8000-000000000001'::uuid,
  '10000000-0000-4000-8000-000000000001'::uuid,
  c.id,
  c.name,
  'active',
  jsonb_build_object(
    'id', c.id, 'name', c.name,
    'image', 'data:image/png;base64,' || encode(convert_to('deleted-session-image', 'UTF8'), 'base64'),
    'opening', 'deleted-snapshot-must-remain-untouched'
  ),
  '{}'::jsonb,
  'story',
  now()
from public.characters c
where right(c.id::text, 12)::integer = 1;
