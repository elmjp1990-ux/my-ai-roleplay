# ayeT-Studios rewarded-video callback integration (draft)

Status: design draft only. This branch is not deployed and the callback scaffold intentionally fails closed.

## Confirmed provider contract (official docs)

- Use a Website Placement + Rewarded Video AdSlot with the HTML5 Rewarded Video SDK. Do not use Offerwall, installation, IAP, IAA, or optional conversion events.
- Enable `Send S2S Callbacks` for video views on the Rewarded Video AdSlot and configure the Callback URL on the Placement.
- Configure the callback URL with provider macros, at minimum `transaction_id`, `external_identifier`, `currency_amount`, and `adslot_id`. Validate the exact adslot ID against the approved Rewarded Video AdSlot allowlist. Do not accept a generic offerwall callback as a video reward.
- The provider documents `transaction_id` as the unique conversion identifier and says callbacks may be resent. Enforce uniqueness in PostgreSQL.
- The provider sends `X-Ayetstudios-Security-Hash`. Its documented HMAC procedure is SHA-256 using the Publisher API Key, over all request parameters sorted alphabetically and URL-encoded as a query string. The signature header itself is not a query parameter. Implement according to the current official docs and test against the provider's Callback Tester before granting rewards.
- The provider says the callback endpoint must reply HTTP 200; otherwise it may retry up to 12 times over one hour. After a valid callback is safely recorded, return 200 for duplicates too, while ensuring duplicates never credit twice. Invalid or unprocessable requests must never credit; response strategy should be tested against provider retry behavior.
- The web SDK supports `externalIdentifier` (3–128 characters) and custom parameters. Set `externalIdentifier` to an opaque PersonaX user identifier, not an email or other sensitive personal data. Never trust a user ID supplied by an arbitrary browser without binding it to an authenticated session.

Official docs:
- HTML5 SDK: https://docs.ayetstudios.com/v/product-docs/rewarded-video/web-integrations/rewarded-video-sdk-for-html5
- Rewarded Video Callbacks: https://docs.ayetstudios.com/v/product-docs/callbacks-and-testing/callbacks/rewarded-video-callbacks
- HMAC Security Hash: https://docs.ayetstudios.com/v/product-docs/callbacks-and-testing/callback-verification/hmac-security-hash-optional

## Requirements

- Browser callbacks may update the UI to “pending”; they must never grant currency.
- Grant silver coins only after a valid S2S callback, with the approved Rewarded Video AdSlot ID and a trusted user mapping.
- Do not trust `currency_amount` as the PersonaX reward amount unless explicitly intended. Prefer a fixed, server-controlled silver-coin reward amount, so callback data cannot choose an arbitrary credit.
- Enforce idempotency in PostgreSQL and update wallet balance + `wallet_transactions` ledger in one database transaction.
- Invalid signature, unsupported event type, missing transaction ID, unknown user mapping, or database failure must never issue a reward.
- Reversal behavior for rewarded-video callbacks is not assumed; confirm with ayeT before enabling any reversal callback behavior.

## Still needs confirmation

1. The actual approved Placement ID and Rewarded Video AdSlot ID from the Publisher dashboard.
2. Whether Taiwan website traffic has live rewarded-video demand for this publisher account.
3. Whether the account and PersonaX content have been approved, and any payout/tax requirements for an individual publisher in Taiwan.
4. Whether reversal callbacks apply to rewarded-video views.
5. Confirmed externalIdentifier mapping format and the fixed PersonaX silver reward amount.

## Planned callback URL

https://ouyewoagbmtqehbofrje.supabase.co/functions/v1/ayet-reward-callback

This URL is only a planned format. Do not enter it into the publisher dashboard until the function is fully implemented, deployed, tested, and the provider payload is verified.

## Safe implementation order

1. Confirm the actual AdSlot ID and exact callback URL macro template in the Publisher dashboard.
2. Implement HMAC verification against the query parameters and provider secret stored only as a Supabase secret.
3. Add a dedicated immutable callback event/idempotency table and a trusted database function.
4. In one database transaction, record the unique provider event, validate user mapping and active-account rules, update `wallet_accounts`, and insert the `wallet_transactions` ledger entry.
5. Test invalid signatures, tampered amounts, wrong AdSlot IDs, duplicate and concurrent deliveries, unknown users, account deletion-pending users, and database errors without granting real rewards.
6. Deploy only after review and explicit approval.


## Read-only schema findings (2026-10-15)

Checked the connected Supabase schema without changing data or deploying code:

- `wallet_accounts` stores one row per user with non-negative `diamonds` and `silver_coins` balances.
- `wallet_transactions` currently has only its primary-key unique index; there is no unique idempotency key on `(user_id, biz_type, reference_id)`. Its existing observed transaction type is `signup_bonus` / `silver_coins`; no chat-spend or ad-reward transaction types have been written yet.
- `chat_sessions` has `id`, `user_id`, `status`, and `deleted_at`; `chat_messages` has `id`, `session_id`, `role`, and `deleted_at`, but no direct `user_id`. A secure charge must verify session ownership by joining `chat_sessions.user_id = auth.uid()`, and must define a stable unique key for the billable user turn.
- `account_is_active()` currently returns false when no user is authenticated or when an `account_deletion_requests` row exists for the signed-in user. The existing wallet initializer uses this guard.
- No Supabase Edge Functions are currently deployed in this project.

## Consequences for implementation

1. Do not add client-side balance updates or allow the browser to choose an arbitrary account ID.
2. A database transaction must lock the wallet row, validate active account and owned/non-deleted chat session, and deduct exactly two units atomically. Proposed default ordering is silver coins first, then diamonds for any remainder, allowing mixed payment; confirm product semantics before release.
3. A server-generated stable turn/request UUID must be reused for retries. The database must enforce idempotency for that charge key, and the charge ledger and wallet update must commit or roll back together. Do not assume `ai_generation_records.request_id` is suitable until the generation flow proves it is generated once per user turn and reused on retry.
4. Reward callback idempotency needs a separate unique provider transaction ID and must credit only a fixed server-side silver amount after signature and approved rewarded-video AdSlot validation.
5. These are design findings only. No SQL was applied, no Edge Function was deployed, and no live wallet rows were changed.


## Chat-turn charging design gate (draft; not yet implemented)

### Why a direct “deduct then call AI” implementation is unsafe

The AI request is an external network operation and cannot be part of the same PostgreSQL transaction as the wallet update. If the wallet is charged before generation and the model call fails, the user could lose currency without receiving a reply. If the wallet is charged only after generation, concurrent retries could generate multiple replies before the charge is settled. The implementation must explicitly model a billable turn and its outcome rather than rely on frontend button state.

### Proposed state machine

- Create one server-controlled `turn_id` (UUID) for a user-initiated generation attempt; every retry of that same attempt must reuse it. Editing a previous message without regenerating must not create a charge.
- Reserve the cost atomically before starting generation, using one DB transaction and a unique constraint on the reservation/turn key. Lock the wallet row, verify `auth.uid()` owns the non-deleted `chat_sessions` row, verify `account_is_active()`, and calculate the deduction deterministically.
- Currency rule proposed for review: spend silver coins first, then diamonds for the remaining cost, with total cost exactly 2. Examples: 2 silver → 2 silver; 1 silver + 1 diamond → 1 each; 2 diamonds → 2 diamonds. If combined balance is below 2, make no wallet change and return a structured insufficient-balance result for the UI to show the rewarded-video modal.
- If generation succeeds, mark the reservation settled and link it to the resulting `ai_generation_records` / assistant message. If generation fails before a usable reply is committed, refund the exact reserved currency split once, using the same turn key and a transactional state transition. A failed or repeated refund must not credit twice.
- The turn state and wallet ledger need database-enforced uniqueness and valid transitions (for example `reserved → settled` or `reserved → refunded`). Never trust the browser to supply user_id, currency split, amount, or final status.

### Required edge cases before release

1. Two concurrent requests with the same `turn_id` reserve/charge only once.
2. Two concurrent distinct turns cannot spend the same last coins into a negative balance.
3. Duplicate success/failure callbacks or HTTP retries cannot settle/refund twice.
4. If a session is deleted or the account enters deletion-pending state before reservation, reject without charge.
5. If AI generation fails, refund exactly the original currency split; if a reply is committed, do not refund due only to a client disconnect.
6. Editing a prior message without regeneration does not call the charge/reservation endpoint.
7. An insufficient balance does not create a partial reservation or partial deduction.
8. The UI must distinguish insufficient balance from network/server errors; only the former should prompt rewarded ads.

### Test-mode scope decision (2026-10-15)

The project owner confirmed that the current environment has no real users and that the fixed demonstration reply may be treated as a billable reply for testing. Therefore, the first end-to-end billing test may charge for the existing fixed demonstration response; real AI-provider integration is not a prerequisite for validating wallet charging and the insufficient-balance UI.

This does not relax server-side wallet security. The frontend must not directly change balances. A secure database RPC must perform the atomic deduction and ledger write, and must verify the authenticated user, active account, session ownership, and idempotency key. The current `case 'message'` handler creates local message IDs, appends the user message and fixed assistant reply, then persists the session; it does not yet call an AI provider. The integration must account for first-message cloud-session creation and avoid showing a free reply when a charge fails. The `message-edit` path must remain uncharged unless the user explicitly regenerates a reply.

### Next implementation sequence

1. Draft a database migration for a per-turn charge ledger and an atomic RPC; do not apply it to the connected Supabase project yet.
2. Define a stable UUID per send attempt and reuse it for retries; ensure the database rejects duplicate charges.
3. Integrate the current fixed demonstration reply with the RPC on the feature branch only, with explicit handling for insufficient balance and server/network errors.
4. Add tests for silver-only, diamond-only, mixed payment, insufficient balance, duplicate request, concurrent requests, deleted/pending-deletion sessions, and save failure/refund behavior.
5. Review the resulting diff before asking the owner to run browser tests. Do not merge or deploy until approved.

### Current action boundary

This document is a design draft committed only to `feat/ayet-rewarded-video-callback`. No production SQL, wallet balance, deployed Edge Function, or production frontend was changed.
