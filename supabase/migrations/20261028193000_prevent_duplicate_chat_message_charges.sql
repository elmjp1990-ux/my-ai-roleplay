-- A durable player message must not be billed under multiple turn IDs.
-- Checked the test project before applying: no duplicate user_message_id rows exist.
CREATE UNIQUE INDEX IF NOT EXISTS chat_turn_charges_user_message_id_uidx
  ON public.chat_turn_charges (user_message_id);
COMMENT ON INDEX public.chat_turn_charges_user_message_id_uidx IS
  'Prevents replaying one persisted player message under a new turn ID to charge the wallet twice.';
