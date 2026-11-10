-- Store player reply suggestions with the exact assistant message so reloads do not
-- depend solely on session_data.roleplayMeta metadata synchronization.
ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS suggested_replies jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.chat_messages
  DROP CONSTRAINT IF EXISTS chat_messages_suggested_replies_valid;

ALTER TABLE public.chat_messages
  ADD CONSTRAINT chat_messages_suggested_replies_valid
  CHECK (
    jsonb_typeof(suggested_replies) = 'array'
    AND jsonb_array_length(suggested_replies) <= 3
  );

-- Backfill any suggestions already captured in session metadata.
UPDATE public.chat_messages AS message
SET suggested_replies = metadata.value -> 'suggestedReplies'
FROM public.chat_sessions AS session
CROSS JOIN LATERAL jsonb_each(
  COALESCE(session.session_data -> 'roleplayMeta', '{}'::jsonb)
) AS metadata(key, value)
WHERE message.session_id = session.id
  AND message.id::text = metadata.key
  AND message.role = 'assistant'
  AND jsonb_typeof(metadata.value -> 'suggestedReplies') = 'array'
  AND jsonb_array_length(metadata.value -> 'suggestedReplies') = 3
  AND message.suggested_replies = '[]'::jsonb;
