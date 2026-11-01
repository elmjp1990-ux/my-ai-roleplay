-- Keep the character display label in the user's own wallet history after chat content purge.
CREATE OR REPLACE FUNCTION public.get_my_wallet_transaction_character_names()
RETURNS TABLE(reference_id text,character_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT wt.reference_id,
    COALESCE(cs.character_name, cs.character_snapshot->>'name', '未知角色') AS character_name
  FROM public.wallet_transactions wt
  JOIN public.chat_turn_charges c ON c.turn_id::text=wt.reference_id
  JOIN public.chat_sessions cs ON cs.id=c.session_id
  WHERE wt.user_id=auth.uid()
    AND wt.biz_type IN ('chat_turn_charge','chat_turn_refund')
    AND cs.user_id=auth.uid();
$function$;
