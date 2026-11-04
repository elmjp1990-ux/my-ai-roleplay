-- Store minimal, non-sensitive AI Gateway response metadata for support diagnostics.
-- Never store provider error messages, prompts, player content, or credentials.
begin;

alter table public.chat_turn_events
  add column if not exists http_status integer,
  add column if not exists gateway_request_id text;

alter table public.chat_turn_events
  add constraint chat_turn_events_http_status_range
  check (http_status is null or http_status between 100 and 599)
  not valid;

alter table public.chat_turn_events
  validate constraint chat_turn_events_http_status_range;

alter table public.chat_turn_events
  add constraint chat_turn_events_gateway_request_id_length
  check (gateway_request_id is null or length(gateway_request_id) <= 128)
  not valid;

alter table public.chat_turn_events
  validate constraint chat_turn_events_gateway_request_id_length;

comment on column public.chat_turn_events.http_status is
  'HTTP status returned by the AI Gateway; populated for provider response diagnostics only.';

comment on column public.chat_turn_events.gateway_request_id is
  'Sanitized AI Gateway request/generation identifier; never contains request or prompt content.';

commit;
