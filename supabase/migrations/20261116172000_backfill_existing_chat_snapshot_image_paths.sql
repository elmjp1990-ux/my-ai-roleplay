-- Backfill stable primary-portrait paths into existing chat snapshots.
-- Only fill a missing/empty imagePath from trusted illustration metadata.
-- Preserve legacy image URLs, all other snapshot fields, and chat updated_at.
-- Rows without a matching primary illustration are intentionally left unchanged.

UPDATE public.chat_sessions AS cs
SET character_snapshot = jsonb_set(
  COALESCE(cs.character_snapshot, '{}'::jsonb),
  '{imagePath}',
  to_jsonb((
    SELECT ci.storage_path
    FROM public.character_illustrations AS ci
    WHERE ci.character_id = cs.character_id
      AND ci.asset_type = 'primary'
      AND NULLIF(btrim(ci.storage_path), '') IS NOT NULL
    ORDER BY ci.sort_order ASC, ci.created_at ASC, ci.id ASC
    LIMIT 1
  )),
  true
)
WHERE cs.deleted_at IS NULL
  AND COALESCE(cs.character_snapshot->>'imagePath', '') = ''
  AND EXISTS (
    SELECT 1
    FROM public.character_illustrations AS ci
    WHERE ci.character_id = cs.character_id
      AND ci.asset_type = 'primary'
      AND NULLIF(btrim(ci.storage_path), '') IS NOT NULL
  );

UPDATE public.chat_group_members AS gm
SET character_snapshot = jsonb_set(
  COALESCE(gm.character_snapshot, '{}'::jsonb),
  '{imagePath}',
  to_jsonb((
    SELECT ci.storage_path
    FROM public.character_illustrations AS ci
    WHERE ci.character_id = gm.character_id
      AND ci.asset_type = 'primary'
      AND NULLIF(btrim(ci.storage_path), '') IS NOT NULL
    ORDER BY ci.sort_order ASC, ci.created_at ASC, ci.id ASC
    LIMIT 1
  )),
  true
)
FROM public.chat_groups AS g
WHERE g.id = gm.group_id
  AND g.deleted_at IS NULL
  AND COALESCE(gm.character_snapshot->>'imagePath', '') = ''
  AND EXISTS (
    SELECT 1
    FROM public.character_illustrations AS ci
    WHERE ci.character_id = gm.character_id
      AND ci.asset_type = 'primary'
      AND NULLIF(btrim(ci.storage_path), '') IS NOT NULL
  );
