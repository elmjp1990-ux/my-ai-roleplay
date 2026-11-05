-- The Story chat-turn transaction RPCs are backend-only operations.
-- They accept an explicit user_id and run as SECURITY DEFINER, so client roles
-- must not be able to invoke them directly through PostgREST.
begin;

revoke all on function public.reserve_chat_turn(uuid, uuid, uuid, uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.settle_chat_turn(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.refund_chat_turn(uuid, uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function public.guard_chat_turn_assistant_insert()
  from public, anon, authenticated;

grant execute on function public.reserve_chat_turn(uuid, uuid, uuid, uuid, uuid)
  to service_role;
grant execute on function public.settle_chat_turn(uuid, uuid, uuid)
  to service_role;
grant execute on function public.refund_chat_turn(uuid, uuid, uuid, text)
  to service_role;

comment on function public.reserve_chat_turn(uuid, uuid, uuid, uuid, uuid) is
  'Backend-only wallet reservation. Execute is restricted to service_role.';
comment on function public.settle_chat_turn(uuid, uuid, uuid) is
  'Backend-only Story turn settlement. Execute is restricted to service_role.';
comment on function public.refund_chat_turn(uuid, uuid, uuid, text) is
  'Backend-only Story turn refund. Execute is restricted to service_role.';

commit;
