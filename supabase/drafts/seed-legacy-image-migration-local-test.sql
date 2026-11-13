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
  ('30000000-0000-4000-8000-' || lpad((n)::text, 12, '0'))::uuid,
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
  case when right(c.id::text, 1)::integer <= 6 then 9 else 10 end
) n
cross join lateral (
  select row_number() over (order by c.id) as character_no
) x
cross join lateral (
  select (x.character_no - 1) * 10 + n as n
) seq;

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
join lateral (
  select id, name from public.characters
  order by id
  offset ((n - 1) % 8) limit 1
) c on true;

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
