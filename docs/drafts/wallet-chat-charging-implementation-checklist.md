# PersonaX wallet and chat charging — implementation checklist

Status: production SQL migration and fixed-demo Edge Function v1 are deployed. Feature-branch frontend is connected in source but is not merged/deployed to the main production website. End-to-end acceptance is not complete.

## P0 — Correctness and wallet safety

- [x] Apply production SQL migration `wallet_chat_turn_charging`.
- [x] Verify `chat_turn_charges`, `chat_turn_events`, the chat-turn wallet transaction idempotency index, reserve/settle/refund RPCs, and the assistant-insert guard exist.
- [x] Verify RLS is enabled on the new tables and direct anon/authenticated SELECT is not granted; service-role access is present.
- [x] Deploy fixed-demo `chat-turn` Edge Function v1 with JWT verification enabled.
- [x] Wire feature-branch frontend to the Edge Function using stable turn/message IDs.
- [x] Use insert-only assistant reply persistence; do not overwrite a colliding message ID.
- [x] Do not refund merely because one read temporarily finds no reply; preserve an ambiguous turn for safe retry/reconciliation.
- [ ] Verify silver-only, diamond-only, mixed payment, and insufficient-balance paths in an isolated repeatable test.
- [ ] Verify reservation, settlement, refund and ledger writes are atomic and idempotent under concurrent calls.
- [ ] Verify a refunded turn can never later deliver a successful reply and a settled turn cannot be refunded.
- [ ] Review and test `supabase/drafts/chat-turn-assistant-update-guard.sql`: the production `chat_messages_update_own` policy permits message updates, while the current billing trigger only guards INSERT. Ensure a charged assistant reply cannot have its ID/session/role/content changed after insertion, while intended soft-delete behavior remains intact. This hardening draft is not applied.
- [ ] Review stale-turn reconciliation SQL draft and test it against the fixed-demo handler before considering production application or scheduling.
- [ ] Do not use the demo stale-turn refund strategy once a real AI provider is integrated; first query provider/job status and distinguish confirmed failure from unknown outcome.
- [ ] Confirm the frontend preserves pending IDs across refresh/relogin and never creates a second turn while the previous result is ambiguous.

## P1 — Persistent operational audit

- [x] Add server-side `chat_turn_events` table with client access withheld.
- [x] Record core reservation, settlement, refund and reconciliation transitions in the SQL/Edge Function source.
- [ ] Add/review sanitized events for all operational failures, retryability, attempt counts and durations.
- [ ] Do not log API keys, authorization/signature headers, raw stack traces, full prompts or generated content.
- [ ] Decide retention and monitoring before public launch.
- [ ] Ensure every failed send reaches a terminal failure/refund outcome or explicit `needs_reconciliation` state.

## P2 — Functional integration and verification

- [x] Route the current fixed demo response through the same charge lifecycle; no real AI provider call is made.
- [x] Roll back local message/memory changes when the initial cloud save fails.
- [x] Wire the feature-branch browser handler to the fixed-demo `chat-turn` Edge Function.
- [ ] Keep edit-without-regeneration free; a new generation is a new billable turn.
- [ ] Verify authoritative wallet balance after success/refund.
- [ ] Test successful reply, insufficient balance, assistant persistence failure, retry, double-click, concurrent turns, refresh/relogin, mixed currency, stale reservation, and lost acknowledgement.
- [ ] Verify UI shows success only after a durable reply and authoritative settlement result.
- [ ] Merge/deploy frontend only after repeatable tests pass and owner approval is obtained.

## P3 — Low-priority presentation polish

- [ ] Add send-button spinner and character typing dots/text.
- [ ] Add 45-second wait message and 90-second status-check presentation.
- [ ] Support dark/light themes and reduced-motion preferences.
- [ ] Treat animation as display only; server turn state remains authoritative.

## Reconciliation draft

`supabase/drafts/chat-turn-assistant-update-guard.sql` is a source-only trigger draft protecting the identity and content of charged assistant replies against later UPDATEs. The production `chat_messages_update_own` policy exists, and the deployed billing trigger currently guards INSERT only; review compatibility with soft-delete behavior before considering application.

`supabase/drafts/chat-turn-stale-reconciliation.sql` contains a source-only function for stale turns in the deterministic demo mode. It is **not applied, not scheduled, and not yet tested**. It locks eligible stale charge rows, settles if a durable non-empty assistant reply exists, otherwise calls the guarded refund RPC. The shared row-locking trigger prevents a late assistant insert after refund. This strategy is valid only while no external provider job can complete later; real AI integration requires provider/job-state reconciliation first.

## Current boundary

The production database migration and Edge Function v1 are deployed, but the feature-branch frontend is not merged/deployed to the production website and no end-to-end acceptance tests have passed. Do not tell the owner to test yet. Do not apply the reconciliation draft, schedule a cron job, merge main, or deploy the frontend without the required review/approval. The current Edge Function returns a fixed demo reply and does not call a real AI provider.
