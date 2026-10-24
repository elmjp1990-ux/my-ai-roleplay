-- Enforce whisper-thread ancestry when authorizing replies.
-- A reply to a public-looking descendant must still be blocked if any ancestor is whisper.
-- Preserve the existing exceptions for the direct parent author and character owner.
create or replace function private.comment_reply_allowed(
  p_parent_id uuid,
  p_character_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.character_comments parent
    left join public.characters ch on ch.id = parent.character_id
    where parent.id = p_parent_id
      and parent.character_id = p_character_id
      and (
        not private.comment_is_whisper_thread(parent.id)
        or parent.author_id = p_user_id
        or ch.author_id = p_user_id
      )
  );
$function$;
