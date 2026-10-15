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
