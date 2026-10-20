-- Keep birthdate and persona presets out of public profile SELECTs.
-- This RPC derives the target user exclusively from auth.uid(), never a client-supplied ID.
create or replace function public.get_my_private_profile_data()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'birthdate', p.birthdate,
    'persona_presets', p.persona_presets
  )
  from public.profiles as p
  where p.id = auth.uid();
$$;

revoke all on function public.get_my_private_profile_data() from public, anon, authenticated;
grant execute on function public.get_my_private_profile_data() to authenticated;
