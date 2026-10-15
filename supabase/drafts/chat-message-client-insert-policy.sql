-- REVIEW ONLY: browser chat-message INSERT hardening for server-authoritative billing.
-- Do not apply to production without owner approval and a reviewed rollback plan.
--
-- The browser should insert/update user-authored turns only. Assistant replies are
-- persisted by the trusted service-role chat-turn Edge Function after reservation.
-- The character opening message is reconstructed from chat_sessions.character_snapshot
-- by the frontend and is not inserted as an assistant row by the browser.
--
-- Existing RLS inspection (2026-10-15) found chat_messages_insert_own permits any role
-- for a session owned by auth.uid(). That lets a browser client create arbitrary
-- assistant-role rows outside the billable chat-turn flow.

begin;

drop policy if exists chat_messages_insert_own on public.chat_messages;

create policy chat_messages_insert_own
on public.chat_messages
for insert
to authenticated
with check (
  role = 'user'
  and (select public.account_is_active())
  and exists (
    select 1
    from public.chat_sessions s
    where s.id = chat_messages.session_id
      and s.user_id = (select auth.uid())
      and s.deleted_at is null
  )
);

comment on policy chat_messages_insert_own on public.chat_messages is
  'Authenticated clients may insert only user-authored messages into their own active chat session. Assistant replies must be persisted by the trusted chat-turn server function.';

commit;

-- Rollback (only if the owner explicitly approves restoring the old policy):
-- drop policy if exists chat_messages_insert_own on public.chat_messages;
-- create policy chat_messages_insert_own on public.chat_messages
-- for insert to authenticated
-- with check (
--   (select public.account_is_active())
--   and exists (
--     select 1 from public.chat_sessions s
--     where s.id = chat_messages.session_id
--       and s.user_id = (select auth.uid())
--   )
-- );
