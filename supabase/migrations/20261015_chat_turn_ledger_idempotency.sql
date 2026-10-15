-- Prevent duplicate chat-turn debit/refund ledger rows for the same currency.
-- The charge/refund RPCs already lock the turn row; this unique index is a
-- final database-level idempotency barrier if a future code path regresses.
CREATE UNIQUE INDEX IF NOT EXISTS wallet_transactions_chat_turn_idempotency_uidx
  ON public.wallet_transactions (user_id, biz_type, reference_id, currency_type)
  WHERE biz_type IN ('chat_turn_charge', 'chat_turn_refund')
    AND reference_id IS NOT NULL;
