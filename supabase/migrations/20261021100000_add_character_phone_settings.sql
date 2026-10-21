alter table public.characters
  add column if not exists phone_settings jsonb not null default '{}'::jsonb;

alter table public.characters
  drop constraint if exists characters_phone_settings_object;

alter table public.characters
  add constraint characters_phone_settings_object
  check (jsonb_typeof(phone_settings) = 'object');
