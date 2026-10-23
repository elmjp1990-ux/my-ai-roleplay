-- Protect direct table reads of whisper comments and every reply in the same thread.
-- The helper is SECURITY DEFINER so it can inspect ancestor rows without recursive RLS.
create or replace function private.comment_is_whisper_thread(p_comment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  with recursive thread as (
    select c.id, c.parent_id, c.is_whisper
    from public.character_comments c
    where c.id = p_comment_id
    union all
    select parent.id, parent.parent_id, parent.is_whisper
    from public.character_comments parent
    join thread child on child.parent_id = parent.id
  )
  select coalesce(bool_or(thread.is_whisper), false)
  from thread;
$function$;

revoke all on function private.comment_is_whisper_thread(uuid) from public;
grant execute on function private.comment_is_whisper_thread(uuid) to anon, authenticated;
grant usage on schema private to anon;

drop policy if exists comments_select_visible on public.character_comments;
create policy comments_select_visible
on public.character_comments
for select
to anon, authenticated
using (
  author_id = (select auth.uid())
  or exists (
    select 1
    from public.characters ch
    where ch.id = character_comments.character_id
      and ch.author_id = (select auth.uid())
  )
  or (
    not private.comment_is_whisper_thread(character_comments.id)
    and exists (
      select 1
      from public.characters ch
      where ch.id = character_comments.character_id
        and ch.visibility = 'public'
        and ch.deleted_at is null
    )
  )
);
