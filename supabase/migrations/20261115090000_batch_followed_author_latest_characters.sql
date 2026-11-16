-- Batch the latest public character previews for one followed-author page.
-- The invoker's existing characters RLS remains the visibility boundary.
CREATE OR REPLACE FUNCTION public.get_public_author_latest_characters(p_author_ids uuid[])
RETURNS TABLE (
  author_id uuid,
  character_data jsonb,
  author_rank bigint
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  WITH requested AS (
    SELECT DISTINCT requested_author_id
    FROM pg_catalog.unnest(p_author_ids) AS requested(requested_author_id)
  ),
  ranked AS (
    SELECT
      c.author_id,
      pg_catalog.jsonb_build_object(
        'id', c.id,
        'author_id', c.author_id,
        'name', c.name,
        'gender', c.gender,
        'age', c.age,
        'avatar_url', c.avatar_url,
        'avatar_video_path', c.avatar_video_path,
        'is_nsfw', c.is_nsfw,
        'visibility', c.visibility,
        'review_status', c.review_status,
        'intro', c.intro,
        'race', c.race,
        'style', c.style,
        'tags', c.tags,
        'created_at', c.created_at,
        'first_published_at', c.first_published_at,
        'latest_eligible', c.latest_eligible
      ) AS character_data,
      pg_catalog.row_number() OVER (
        PARTITION BY c.author_id
        ORDER BY c.first_published_at DESC NULLS LAST, c.id DESC
      ) AS author_rank
    FROM public.characters AS c
    JOIN requested AS r ON r.requested_author_id = c.author_id
    WHERE p_author_ids IS NOT NULL
      AND pg_catalog.cardinality(p_author_ids) BETWEEN 1 AND 10
      AND c.visibility = 'public'
      AND c.deleted_at IS NULL
  )
  SELECT ranked.author_id, ranked.character_data, ranked.author_rank
  FROM ranked
  WHERE ranked.author_rank <= 5
  ORDER BY ranked.author_id, ranked.author_rank;
$$;

REVOKE ALL ON FUNCTION public.get_public_author_latest_characters(uuid[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_public_author_latest_characters(uuid[])
  TO authenticated;

COMMENT ON FUNCTION public.get_public_author_latest_characters(uuid[]) IS
  'Returns at most five latest public, non-deleted character previews per supplied author (up to ten authors). SECURITY INVOKER preserves existing characters table grants and RLS.';
