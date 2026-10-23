-- Ensure the safe comments RPC masks replies at any depth inside a whisper thread.
-- This uses the same ancestry-aware helper as the direct table RLS policy.
create or replace function public.get_character_comments_safe(p_character_id uuid)
returns table(
  id uuid,
  character_id uuid,
  author_id uuid,
  content text,
  parent_id uuid,
  is_whisper boolean,
  is_deleted boolean,
  created_at timestamptz,
  updated_at timestamptz,
  is_redacted boolean
)
language sql
stable
security definer
set search_path to ''
as $function$
  with me as (select auth.uid() as uid),
  ch as (
    select c.id, c.author_id as character_author_id
    from public.characters c
    where c.id = p_character_id
      and ((c.visibility = 'public' and c.deleted_at is null) or c.author_id = auth.uid())
  )
  select cm.id, cm.character_id, cm.author_id,
    case
      when cm.is_deleted then '該筆評論已被刪除'
      when private.comment_is_whisper_thread(cm.id)
       and cm.author_id is distinct from me.uid
       and ch.character_author_id is distinct from me.uid
       and coalesce(parent.author_id, cm.author_id) is distinct from me.uid
        then '這是一則悄悄話留言'
      else cm.content
    end,
    cm.parent_id, cm.is_whisper, cm.is_deleted, cm.created_at, cm.updated_at,
    (
      not cm.is_deleted
      and private.comment_is_whisper_thread(cm.id)
      and cm.author_id is distinct from me.uid
      and ch.character_author_id is distinct from me.uid
      and coalesce(parent.author_id, cm.author_id) is distinct from me.uid
    ) as is_redacted
  from public.character_comments cm
  join ch on ch.id = cm.character_id
  cross join me
  left join public.character_comments parent on parent.id = cm.parent_id
  where cm.character_id = p_character_id
  order by cm.created_at asc;
$function$;
