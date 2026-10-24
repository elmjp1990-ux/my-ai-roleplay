-- PersonaX: character NSFW classification, configurable trigger terms, and server-side age gate.
-- The NSFW keyword scan is a creation/review warning, not a content classifier or a replacement for moderation.
ALTER TABLE public.characters
  ADD COLUMN IF NOT EXISTS is_nsfw boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.current_user_is_adult()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles AS p
    WHERE p.id = (SELECT auth.uid())
      AND p.birthdate IS NOT NULL
      AND p.birthdate <= (CURRENT_DATE - INTERVAL '18 years')::date
  );
$$;

REVOKE ALL ON FUNCTION public.current_user_is_adult() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.current_user_is_adult() TO anon, authenticated;

-- Both existing public SELECT policies must include the same age gate because permissive
-- policies are OR-ed together by PostgreSQL RLS.
DROP POLICY IF EXISTS "characters_hide_soft_deleted_from_non_owner" ON public.characters;
CREATE POLICY "characters_hide_soft_deleted_from_non_owner"
ON public.characters
FOR SELECT
TO anon, authenticated
USING (
  author_id = (SELECT auth.uid())
  OR (
    visibility = 'public'
    AND deleted_at IS NULL
    AND (
      is_nsfw IS NOT TRUE
      OR ((SELECT auth.uid()) IS NOT NULL AND public.current_user_is_adult())
    )
  )
);

DROP POLICY IF EXISTS "公開檢視公開且未下架的角色" ON public.characters;
CREATE POLICY "公開檢視公開且未下架的角色"
ON public.characters
FOR SELECT
TO anon, authenticated
USING (
  visibility = 'public'
  AND deleted_at IS NULL
  AND (
    is_nsfw IS NOT TRUE
    OR ((SELECT auth.uid()) IS NOT NULL AND public.current_user_is_adult())
  )
);

CREATE TABLE IF NOT EXISTS public.content_restriction_terms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  term text NOT NULL UNIQUE CHECK (length(btrim(term)) BETWEEN 1 AND 80),
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.content_restriction_terms ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.content_restriction_terms FROM PUBLIC;
GRANT SELECT ON public.content_restriction_terms TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.content_restriction_terms TO authenticated;

DROP POLICY IF EXISTS "Anyone can read active restriction terms" ON public.content_restriction_terms;
CREATE POLICY "Anyone can read active restriction terms"
ON public.content_restriction_terms
FOR SELECT TO anon, authenticated
USING (is_active = true OR (SELECT auth.jwt()->'app_metadata'->>'role') = 'admin');

DROP POLICY IF EXISTS "Only admins manage restriction terms" ON public.content_restriction_terms;
CREATE POLICY "Only admins manage restriction terms"
ON public.content_restriction_terms
FOR ALL TO authenticated
USING ((SELECT auth.jwt()->'app_metadata'->>'role') = 'admin')
WITH CHECK ((SELECT auth.jwt()->'app_metadata'->>'role') = 'admin');

INSERT INTO public.content_restriction_terms (term, is_active)
VALUES
  ('18禁', true), ('成人內容', true), ('色情', true), ('情色', true),
  ('露骨性', true), ('性描寫', true), ('性器官', true), ('性交', true),
  ('做愛', true), ('口交', true), ('肛交', true), ('自慰', true),
  ('手淫', true), ('高潮', true), ('裸露', true), ('裸體', true),
  ('乳房', true), ('陰莖', true), ('陰道', true), ('性奴', true),
  ('性侵', true), ('強姦', true), ('亂倫', true), ('NSFW', true)
ON CONFLICT (term) DO NOTHING;

COMMENT ON COLUMN public.characters.is_nsfw IS
  'Creator-declared adult/sensitive classification; public SELECT is gated by profile birthdate via RLS.';
COMMENT ON TABLE public.content_restriction_terms IS
  'Configurable terms used only to prompt creator NSFW review. Admin mutation requires auth.jwt app_metadata role=admin.';
