# ayeT-Studios rewarded-video callback integration (draft)

Status: design draft only. This branch is not deployed and this callback is intentionally fail-closed.

## Requirements

- Reward only HTML5 Rewarded Video views; never installations, IAP, IAA, offerwall, or optional conversions.
- The browser SDK may display a pending state, but must never grant currency.
- Grant currency only after a valid ayeT-Studios S2S callback.
- Verify the provider's documented signature against the exact raw request body and server-side secret. Do not guess canonicalization or query parameter names.
- Require a documented unique provider transaction identifier and bind it to the PersonaX user using a server-issued, unguessable reward session/token. Never trust a user ID supplied by the browser or callback without authenticated mapping.
- Enforce idempotency in PostgreSQL and update wallet balance + ledger in one database transaction.
- Invalid signature, unknown user mapping, unsupported event type, missing transaction ID, duplicate event, or database failure must never issue a second reward.
- Define reversal/chargeback behavior only after ayeT confirms whether reversal callbacks apply to rewarded-video views.

## Provider confirmations still required

1. Exact callback payload/query parameters for rewarded video views.
2. Exact X-Ayetstudios-Security-Hash HMAC input/canonicalization and encoding.
3. Which field uniquely identifies a completed view (transaction_id or other documented field).
4. How the provider securely returns the PersonaX user / reward-session reference.
5. Whether Taiwan website traffic and individual publisher accounts are approved and have live video demand.
6. Reversal behavior for rewarded video.

## Planned callback URL

https://ouyewoagbmtqehbofrje.supabase.co/functions/v1/ayet-reward-callback

This URL is only a planned format. Do not enter it into the publisher dashboard until the function is fully implemented, deployed, tested, and the provider payload is verified.

## Safe implementation order

1. Obtain the exact provider callback specification.
2. Implement signature verification and event allowlisting.
3. Add the migration for a dedicated immutable callback event/idempotency table.
4. Add a SECURITY DEFINER database function that validates event uniqueness and atomically updates wallet_accounts and wallet_transactions.
5. Test signature failures, duplicate deliveries, concurrent duplicate deliveries, unknown users, and database errors using test fixtures without issuing real rewards.
6. Deploy only after review and explicit approval.
