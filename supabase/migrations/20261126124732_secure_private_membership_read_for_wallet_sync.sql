-- Keep membership data private while allowing the signed-in owner to read it.
REVOKE SELECT (membership_tier, membership_expires_at)
ON TABLE public.profiles
FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_my_private_profile_data()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'birthdate', p.birthdate,
    'persona_presets', p.persona_presets,
    'membership_tier', p.membership_tier,
    'membership_expires_at', p.membership_expires_at
  )
  FROM public.profiles AS p
  WHERE p.id = auth.uid();
$function$;
