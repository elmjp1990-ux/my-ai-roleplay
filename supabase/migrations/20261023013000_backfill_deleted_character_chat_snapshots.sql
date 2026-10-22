-- Backfill snapshots for characters deleted before group snapshot sync was added.
UPDATE public.chat_group_members gm
SET character_snapshot = COALESCE(gm.character_snapshot, '{}'::jsonb) ||
  jsonb_build_object('authorId', c.author_id, 'visibility', 'private',
    'firstPublishedAt', c.first_published_at, 'deletedAt', c.deleted_at)
FROM public.characters c
WHERE gm.character_id = c.id AND c.deleted_at IS NOT NULL
  AND (gm.character_snapshot->>'deletedAt' IS DISTINCT FROM c.deleted_at::text
    OR gm.character_snapshot->>'visibility' IS DISTINCT FROM 'private'
    OR gm.character_snapshot->>'authorId' IS DISTINCT FROM c.author_id::text);

UPDATE public.chat_group_messages gm
SET speaker_snapshot = COALESCE(gm.speaker_snapshot, '{}'::jsonb) ||
  jsonb_build_object('authorId', c.author_id, 'visibility', 'private',
    'firstPublishedAt', c.first_published_at, 'deletedAt', c.deleted_at)
FROM public.characters c
WHERE gm.character_id = c.id AND c.deleted_at IS NOT NULL
  AND (gm.speaker_snapshot->>'deletedAt' IS DISTINCT FROM c.deleted_at::text
    OR gm.speaker_snapshot->>'visibility' IS DISTINCT FROM 'private'
    OR gm.speaker_snapshot->>'authorId' IS DISTINCT FROM c.author_id::text);

UPDATE public.chat_sessions cs
SET character_snapshot = COALESCE(cs.character_snapshot, '{}'::jsonb) ||
  jsonb_build_object('authorId', c.author_id, 'visibility', 'private',
    'firstPublishedAt', c.first_published_at, 'deletedAt', c.deleted_at),
    updated_at = now()
FROM public.characters c
WHERE cs.character_id = c.id AND c.deleted_at IS NOT NULL
  AND (cs.character_snapshot->>'deletedAt' IS DISTINCT FROM c.deleted_at::text
    OR cs.character_snapshot->>'visibility' IS DISTINCT FROM 'private'
    OR cs.character_snapshot->>'authorId' IS DISTINCT FROM c.author_id::text);
