-- Preserve provider-failure usage telemetry when no assistant message was created.
-- Successful chat_response records still require an assistant_message_id.
ALTER TABLE public.ai_model_usage
  DROP CONSTRAINT IF EXISTS ai_model_usage_generation_fields_check;

ALTER TABLE public.ai_model_usage
  ADD CONSTRAINT ai_model_usage_generation_fields_check CHECK (
    (
      generation_type = 'chat_response'
      AND turn_id IS NOT NULL
      AND (assistant_message_id IS NOT NULL OR status = 'failed')
      AND batch_number IS NULL
      AND cardinality(source_turn_ids) = 0
      AND summary IS NULL
    )
    OR (
      generation_type = 'memory_summary'
      AND turn_id IS NULL
      AND assistant_message_id IS NULL
      AND batch_number IS NOT NULL
      AND batch_number > 0
      AND cardinality(source_turn_ids) BETWEEN 1 AND 5
    )
  );
