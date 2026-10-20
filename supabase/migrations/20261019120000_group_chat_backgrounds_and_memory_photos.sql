-- Group-specific chat background settings and private group memory photos.
ALTER TABLE public.chat_groups
  ADD COLUMN IF NOT EXISTS background_mode text NOT NULL DEFAULT 'avatar'
    CHECK (background_mode IN ('avatar','none','memory')),
  ADD COLUMN IF NOT EXISTS background_memory_photo_id uuid NULL;

CREATE TABLE IF NOT EXISTS public.chat_group_memory_photos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  image_url text NOT NULL,
  caption text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chat_group_memory_photos_group_created_idx
  ON public.chat_group_memory_photos(group_id, created_at DESC);

ALTER TABLE public.chat_group_memory_photos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS chat_group_memory_photos_owner_select ON public.chat_group_memory_photos;
CREATE POLICY chat_group_memory_photos_owner_select
  ON public.chat_group_memory_photos FOR SELECT TO authenticated
  USING (owner_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS chat_group_memory_photos_owner_insert ON public.chat_group_memory_photos;
CREATE POLICY chat_group_memory_photos_owner_insert
  ON public.chat_group_memory_photos FOR INSERT TO authenticated
  WITH CHECK (
    owner_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = group_id AND g.owner_id = (SELECT auth.uid())
    )
  );

DROP POLICY IF EXISTS chat_group_memory_photos_owner_delete ON public.chat_group_memory_photos;
CREATE POLICY chat_group_memory_photos_owner_delete
  ON public.chat_group_memory_photos FOR DELETE TO authenticated
  USING (
    owner_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1 FROM public.chat_groups g
      WHERE g.id = group_id AND g.owner_id = (SELECT auth.uid())
    )
  );

COMMENT ON TABLE public.chat_group_memory_photos IS 'Private memory photos belonging only to their own group; never sourced from individual chats.';
COMMENT ON COLUMN public.chat_groups.background_mode IS 'Group chat background mode: avatar carousel, none, or a group-owned memory photo.';
