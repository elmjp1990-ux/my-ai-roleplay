-- Enable pg_net for the scheduled chat-deletion Edge Function invocation.
-- The schedule itself is intentionally added only after end-to-end worker tests pass.
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
