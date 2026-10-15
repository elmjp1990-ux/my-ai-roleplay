-- Freeze direct group-chat table access while an account deletion request is pending.
-- Restrictive policies are ANDed with existing owner policies, so they do not
-- broaden access and keep ownership checks intact.
DO $migration$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'chat_groups',
    'chat_group_scenes',
    'chat_group_members',
    'chat_group_turns',
    'chat_group_messages'
  ]
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.%I',
      'pending_deletion_account_active_only',
      v_table
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING ((SELECT public.account_is_active())) WITH CHECK ((SELECT public.account_is_active()))',
      'pending_deletion_account_active_only',
      v_table
    );
  END LOOP;
END;
$migration$;
