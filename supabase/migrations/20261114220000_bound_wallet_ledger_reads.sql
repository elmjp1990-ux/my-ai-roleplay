-- Bound wallet character-name hydration to the current ten-row ledger page.
CREATE OR REPLACE FUNCTION public.get_my_wallet_transaction_character_names_page(p_reference_ids text[])
RETURNS TABLE(reference_id text, character_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT wt.reference_id,
         COALESCE(cs.character_name, cs.character_snapshot->>'name', '未知角色') AS character_name
  FROM public.wallet_transactions wt
  JOIN public.chat_turn_charges c ON c.turn_id::text = wt.reference_id
  JOIN public.chat_sessions cs ON cs.id = c.session_id
  WHERE wt.user_id = (SELECT auth.uid())
    AND wt.biz_type IN ('chat_turn_charge', 'chat_turn_refund')
    AND cs.user_id = (SELECT auth.uid())
    AND p_reference_ids IS NOT NULL
    AND pg_catalog.cardinality(p_reference_ids) BETWEEN 1 AND 10
    AND wt.reference_id = ANY (p_reference_ids);
$function$;

REVOKE ALL ON FUNCTION public.get_my_wallet_transaction_character_names_page(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_wallet_transaction_character_names_page(text[]) TO authenticated;

COMMENT ON FUNCTION public.get_my_wallet_transaction_character_names_page(text[]) IS
  'Returns character labels only for up to ten supplied wallet transaction references owned by auth.uid(); intended for one bounded wallet-ledger page.';
