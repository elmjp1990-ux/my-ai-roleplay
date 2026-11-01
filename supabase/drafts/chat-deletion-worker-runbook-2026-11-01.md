# Chat deletion worker runbook — test project

Date: 2026-11-01  
PR: #200  
Function: `purge-chat-deletions`  
Project: `ouyewoagbmtqehbofrje`  
Status: deployed to the test project; not invoked and not scheduled.

## Purpose

Process the shared 30-day deletion queues for single and group chats. The worker is service-role-only and handles relational content purge first, then chat-memory Storage objects.

## Safety contract

- Only process jobs where `purge_after <= now()`.
- The relational purge retains minimal session/group/message/turn tombstones so charge and wallet evidence foreign keys remain valid.
- It clears chat message content, message versions, AI raw content, chat snapshots, encounter/story summaries and chat-only diary/media metadata.
- It preserves `chat_turn_charges`, `chat_group_turn_charges`, `chat_turn_events`, wallet ledger rows, group turn IDs, and global encounter affinity state.
- Storage deletion is restricted to `personax-memory-photos`; character illustration/video buckets are not accepted.
- Storage paths are copied into the durable Storage queue before any chat photo metadata is purged.
- Failures are retried with bounded exponential backoff; after eight attempts they become `dead_letter`.
- Never log object paths, signed URLs, message content, prompts, or raw error messages.

## Invocation

The Edge Function has JWT verification enabled and additionally requires the JWT role claim `service_role`.

Send a POST request to the deployed function URL using the service-role key as the Bearer token. Never put the service-role key in browser code, a public repository, or a user-facing client.

The function processes at most:
- 10 due relational chat deletion jobs per invocation.
- 50 due Storage object jobs per invocation.

The response contains counts only; it does not return chat IDs or object paths.

## Current deployment controls

- Function is deployed only to the test Supabase project.
- No pg_cron, external cron, Vercel Cron, or other schedule has been created.
- The worker has not been invoked against persistent jobs.
- The SQL claim/purge/retry RPCs have been exercised inside rollback-only test transactions.
- Actual Storage API deletion with a disposable object remains an outstanding end-to-end test.

## Before enabling any schedule

1. Run a disposable Storage upload/remove test in the test bucket and verify retry behavior.
2. Run a real due-job test using a dedicated test fixture, verify content purge and ledger preservation, then confirm Storage queue completion.
3. Verify dead-letter monitoring and a documented manual recovery procedure.
4. Verify account deletion does not cascade-delete pending chat deletion jobs or Storage jobs.
5. Obtain explicit approval before creating any cron schedule; production scheduling requires separate approval.
