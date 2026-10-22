-- Keep profile writes compatible with column-level grants without exposing private fields.
-- Every write is bound to auth.uid() and blocked for accounts pending deletion.
CREATE OR REPLACE FUNCTION public.save_my_profile(
  p_handle text,
  p_nickname text,
  p_avatar_url text DEFAULT NULL,
  p_bio text DEFAULT '',
  p_birthdate date DEFAULT NULL,
  p_persona_presets jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF NOT public.account_is_active() THEN
    RAISE EXCEPTION 'Account is not active';
  END IF;

  IF NULLIF(btrim(p_handle), '') IS NULL THEN
    RAISE EXCEPTION 'Handle is required';
  END IF;

  IF NULLIF(btrim(p_nickname), '') IS NULL THEN
    RAISE EXCEPTION 'Nickname is required';
  END IF;

  IF p_persona_presets IS NULL OR jsonb_typeof(p_persona_presets) <> 'array' THEN
    RAISE EXCEPTION 'Persona presets must be a JSON array';
  END IF;

  INSERT INTO public.profiles (
    id, handle, nickname, avatar_url, bio, birthdate, persona_presets
  )
  VALUES (
    v_user_id,
    btrim(p_handle),
    btrim(p_nickname),
    p_avatar_url,
    COALESCE(p_bio, ''),
    p_birthdate,
    p_persona_presets
  )
  ON CONFLICT (id) DO UPDATE SET
    handle = EXCLUDED.handle,
    nickname = EXCLUDED.nickname,
    avatar_url = EXCLUDED.avatar_url,
    bio = EXCLUDED.bio,
    birthdate = EXCLUDED.birthdate,
    persona_presets = EXCLUDED.persona_presets
  RETURNING jsonb_build_object(
    'id', id,
    'handle', handle,
    'nickname', nickname,
    'avatar_url', avatar_url,
    'bio', bio,
    'follower_count', follower_count
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.save_my_profile(text, text, text, text, date, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_my_profile(text, text, text, text, date, jsonb) TO authenticated;
