-- Allow an authenticated player to resolve their own wallet charge to a chat session title.
-- Keep this scoped to the current user and block accounts pending deletion.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_turn_charges'
      AND policyname = 'chat_turn_charges_owner_select'
  ) THEN
    CREATE POLICY "chat_turn_charges_owner_select"
      ON public.chat_turn_charges
      FOR SELECT
      TO authenticated
      USING (
        user_id = (SELECT auth.uid())
        AND (SELECT public.account_is_active())
      );
  END IF;
END
$$;
