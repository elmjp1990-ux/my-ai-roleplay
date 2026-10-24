DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'characters_avatar_video_path_owner_check'
      AND conrelid = 'public.characters'::regclass
  ) THEN
    ALTER TABLE public.characters
      ADD CONSTRAINT characters_avatar_video_path_owner_check
      CHECK (
        avatar_video_path IS NULL
        OR avatar_video_path LIKE (author_id::text || '/' || id::text || '/%')
      );
  END IF;
END
$$;
