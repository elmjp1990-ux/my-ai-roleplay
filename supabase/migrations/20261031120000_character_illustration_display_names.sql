alter table public.character_illustrations add column if not exists display_name text not null default '';
comment on column public.character_illustrations.display_name is 'Creator-provided label for a primary or gallery illustration.';
