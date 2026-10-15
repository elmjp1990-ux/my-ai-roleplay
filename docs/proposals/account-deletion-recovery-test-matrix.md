# Expired account recovery test matrix (disposable Supabase project only)

This matrix is a release gate, not evidence that tests have passed. Do not run destructive cases in production.

## Setup
- Use a separate disposable Supabase project with the same migrations and function ACLs.
- Create dedicated synthetic test users and minimal related rows. Do not copy production personal data.
- Use the actual deployed request/archive functions from that test project.
- Record schema/migration commit SHA and test project ID in the test report; do not put user tokens or secrets in the report.

## Required cases

| Case | Setup | Expected result | Must remain unchanged |
|---|---|---|---|
| Unauthenticated | No auth.uid() claim | RPC denied / login required | All tables |
| No request | Signed-in synthetic user, no request row | Stable no-request result; no audit row | Profile, wallet, content |
| Before deadline | Request deadline in future | Recovery RPC refuses and directs normal cancellation | Request row and data |
| Expired, no batch | Expired request, no batch | Recovery succeeds once; request blocker removed; audit event written atomically | Profile, wallet balances, characters, chats |
| Null deadline | Request scheduled_for is NULL | Manual review required | All tables |
| Archived batch reconciles | Archived batch with exact AI/wallet source rows and payloads | Recovery succeeds only if all checks pass | Source/archive rows and balances |
| Missing archived item | Delete one synthetic archive item in test setup | Refuse with archive mismatch | Request remains; all source rows remain |
| Payload mismatch | Change a synthetic archive payload | Refuse with payload mismatch | Request remains; source rows remain |
| Extra/multiple archived batches | Two archived batches for same synthetic user | Manual review required | All tables |
| Destructive/unknown batch | Batch status deleting, archiving, failed, completed or any unknown status | Manual review required | All tables |
| Concurrent recovery | Two sessions invoke recovery at once | At most one success; no duplicate audit success event | No duplicate request transitions |
| Race with archive worker | Recovery and archive lock same request concurrently | One path obtains lock; no partial state; result matches winner | No data loss |
| Repeat after success | Invoke recovery again | Stable idempotent response; no second recovery event | All unrelated data |
| Cross-account attempt | User A calls RPC while user B has request | Only A's request can be considered | B's request and data |
| Direct audit-table access | authenticated/anon attempt SELECT/INSERT/UPDATE/DELETE | Denied | Audit table |
| RPC ACL | anon/PUBLIC attempts execute; authenticated invokes as self | Deny anon; permit intended authenticated call | No privilege leakage |
| Existing request deadline | Existing request before changing default | Deadline unchanged | Existing request timestamps |
| New request default | New synthetic request after migration | scheduled_for approximately 30 days after request time | Other users/rows |

## Assertions after every refusal
- Request row remains and the account is not silently unlocked.
- No audit event with outcome recovered was inserted.
- No source row, archive row, wallet balance, character, conversation or message was deleted or altered.

## Assertions after success
- Exactly one successful recovery audit event exists for that request lifecycle.
- Request blocker is removed (or transitioned if lifecycle columns are adopted).
- Auth identity, profile, wallet balances, character/story/chat data and source/archive rows are unchanged.
- The UI reports success only after the RPC explicitly confirms success and a fresh profile/wallet load completes.

## Stop conditions
Any failed assertion, unknown batch state, missing source row, mismatched payload, unexpected permission, or inability to run true concurrent sessions blocks release. Do not bypass a failed case by loosening production security.
