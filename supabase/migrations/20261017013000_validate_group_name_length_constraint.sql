-- Validate the 1–25 character group-name constraint after confirming existing test rows comply.
-- The NOT VALID constraint already rejects new invalid writes; validation also proves existing rows comply.
ALTER TABLE public.chat_groups
  VALIDATE CONSTRAINT chat_groups_name_max_25;
