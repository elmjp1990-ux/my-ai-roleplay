-- Store free-form schedule descriptions separately from public character fields.
-- The description is author-only and is not consumed by public city schedule resolvers.
CREATE TABLE IF NOT EXISTS public.character_schedule_descriptions (
  character_id uuid PRIMARY KEY REFERENCES public.characters(id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 20000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.character_schedule_descriptions IS
  'Author-only natural-language schedule descriptions. Raw text is never exposed to public city schedule resolvers.';
ALTER TABLE public.character_schedule_descriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.character_schedule_descriptions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.character_schedule_descriptions TO authenticated;
DROP POLICY IF EXISTS character_schedule_descriptions_select_author ON public.character_schedule_descriptions;
CREATE POLICY character_schedule_descriptions_select_author ON public.character_schedule_descriptions
  FOR SELECT TO authenticated USING (
    author_id = (SELECT auth.uid()) AND EXISTS (
      SELECT 1 FROM public.characters c WHERE c.id = character_schedule_descriptions.character_id
      AND c.author_id = (SELECT auth.uid()) AND c.deleted_at IS NULL
    )
  );
DROP POLICY IF EXISTS character_schedule_descriptions_insert_author ON public.character_schedule_descriptions;
CREATE POLICY character_schedule_descriptions_insert_author ON public.character_schedule_descriptions
  FOR INSERT TO authenticated WITH CHECK (
    author_id = (SELECT auth.uid()) AND EXISTS (
      SELECT 1 FROM public.characters c WHERE c.id = character_schedule_descriptions.character_id
      AND c.author_id = (SELECT auth.uid()) AND c.deleted_at IS NULL
    )
  );
DROP POLICY IF EXISTS character_schedule_descriptions_update_author ON public.character_schedule_descriptions;
CREATE POLICY character_schedule_descriptions_update_author ON public.character_schedule_descriptions
  FOR UPDATE TO authenticated USING (
    author_id = (SELECT auth.uid()) AND EXISTS (
      SELECT 1 FROM public.characters c WHERE c.id = character_schedule_descriptions.character_id
      AND c.author_id = (SELECT auth.uid()) AND c.deleted_at IS NULL
    )
  ) WITH CHECK (
    author_id = (SELECT auth.uid()) AND EXISTS (
      SELECT 1 FROM public.characters c WHERE c.id = character_schedule_descriptions.character_id
      AND c.author_id = (SELECT auth.uid()) AND c.deleted_at IS NULL
    )
  );
DROP POLICY IF EXISTS character_schedule_descriptions_delete_author ON public.character_schedule_descriptions;
CREATE POLICY character_schedule_descriptions_delete_author ON public.character_schedule_descriptions
  FOR DELETE TO authenticated USING (
    author_id = (SELECT auth.uid()) AND EXISTS (
      SELECT 1 FROM public.characters c WHERE c.id = character_schedule_descriptions.character_id
      AND c.author_id = (SELECT auth.uid()) AND c.deleted_at IS NULL
    )
  );