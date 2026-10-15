# Group Chat Core — Implementation Plan

Status: staged implementation. The frontend wizard now uses Supabase for group listing, creation, and persisted deterministic mock turns. Test database migrations `20261015141259_group_chat_core_schema`, `20261015141609_group_chat_mock_turns`, and `20261015141936_group_chat_group_activity` are applied. Shared-scene creation, malformed-input rejection, turn persistence/idempotency, non-owner isolation, and invalid scene-position rejection passed in rolled-back database tests. Browser interaction and full separate-scene end-to-end tests remain incomplete.
AI provider integration is intentionally out of scope for the initial build. Complete deterministic/mock orchestration, persistence, permissions, and wallet boundaries before connecting AI.

## Goals

- A group contains 1–3 characters; the server is authoritative for the limit.
- Group creation has three steps: name, shared world background, and initial scene setup.
- Initial scene mode supports characters sharing one scene or starting in separate scenes.
- A deterministic director interface produces an ordered list of speakers. The first implementation uses a mock director, not an AI call.
- Group chat must not bypass existing authentication, row-level security, message persistence, or wallet charging rules.
- Existing single-character chats, memories, diary, album, and archive behavior must remain unchanged.

## Proposed domain model

Use new group-specific records rather than overloading single-character `chat_sessions` before existing call sites have been audited.

- `chat_groups`: id, owner_id, name, world_background, scene_mode (`shared` | `separate`), created_at, updated_at, archived_at (nullable).
- `chat_group_members`: id, group_id, character_id, position (1–3), scene_id (nullable for shared-scene mode), character_snapshot (JSON), created_at. Unique(group_id, character_id) and unique(group_id, position).
- `chat_group_scenes`: id, group_id, name, scene_description, position, created_at. Used when the group starts in separate scenes; shared-scene mode can use one scene.
- `chat_group_messages`: id, group_id, scene_id (nullable), speaker_type (`user` | `character` | `system`), character_id (nullable), content, turn_id, sequence_no, created_at. Keep one turn identifier for messages generated in the same user submission.
- `chat_group_turns`: id, group_id, user_id, request_key, request_content, status (`completed` in mock phase), created_at, completed_at. The request key is unique per group and prevents duplicate mock messages. Wallet reservation/settlement fields are intentionally not implemented yet.

The five core group tables and the checked create/mock-turn RPCs are applied to the test Supabase project. Wallet reservation/settlement and real AI integration remain out of scope until their idempotency and failure paths are reviewed.

## Three-step creation flow

1. Group name: trim whitespace; reject empty names and enforce the same documented maximum in UI and server validation.
2. World background: save shared setting and optionally seed context from selected characters without overwriting their canonical profiles.
3. Initial scene: choose shared scene or separate scenes; validate that each member has a valid scene assignment in separate mode; show a final review before creation.

Creation should be atomic: either the group, member snapshots, and initial scenes are all created, or none are. Avoid leaving orphaned members/scenes after a failed request.

## Character limit and access control

- UI prevents adding a fourth character for usability.
- Server/database enforces the hard limit to prevent concurrent requests from bypassing it. Prefer a transactional RPC or another concurrency-safe mechanism; a simple client count is insufficient.
- Only the owner (and explicitly authorized future participants, if that feature is later specified) can read or modify the group.
- Validate ownership of every character before adding it. Do not trust client-supplied owner IDs.
- Snapshot the character settings required for continuity; do not copy private fields into public group records unless existing access rules explicitly permit it.
- Apply RLS to every new table and test authenticated owner, authenticated non-owner, and anon access.

## Mock director contract

Input: group configuration, scene membership, recent group messages, and the list of available characters.

Output: ordered speaker IDs plus a short, structured reason/turn metadata. The mock implementation should be deterministic and easy to test. It must never call an AI provider.

Validation: speaker IDs must be group members, no duplicate speaker in a single ordered turn unless explicitly allowed, and every output must be bounded by a configurable maximum number of speakers. Separate-scene mode must not select a character from an unrelated scene unless the scene transition is explicit.

## Wallet boundary (do not implement real debit in the mock phase)

- Reuse the existing wallet service/ledger and idempotency strategy; do not create a parallel balance system.
- Define a single group-turn request key so retries cannot double-charge.
- If charging is per user submission, reserve once for the turn and settle only after a valid response has been persisted; release the reservation on provider failure. If pricing is per character response, record each response as a separately idempotent charge unit. Product decision must be confirmed before real charging is enabled.
- During the initial mock phase, use an explicit test mode and do not mutate real balances or ledger entries.
- Keep AI-provider failures and mock errors distinguishable.

## Suggested implementation sequence

1. Read existing chat-session/message persistence, character snapshots, RLS, and wallet code; document integration points.
2. Add group-domain types and pure validators (1–3 members, scene-mode validation, director output validation).
3. Build the three-step creation UI with mock data and local/test persistence; add accessible loading, validation, and error states.
4. Add group list/detail/chat shell and deterministic mock director. (Implemented in the test branch; browser regression still required.)
5. Add migrations and RLS policies after checking the live schema; applied to the test Supabase project. Owner creation, anon function denial, and non-owner read/write isolation have smoke-test coverage; broaden tests before release.
6. Integrate the existing wallet service in test mode with idempotency and failure rollback tests.
7. Add three-character acceptance tests for context boundaries, speaker ordering, scenes, permissions, and charging.
8. Only after the above pass, connect the AI provider and run end-to-end tests.

## Acceptance checklist

- [ ] Create group with a valid name, world background, and shared scene.
- [ ] Create group with separate scenes and validate every character-to-scene assignment.
- [ ] Reject blank/oversized names and invalid scene payloads on both client and server.
- [ ] Add 1, 2, and 3 characters successfully; reject the fourth in UI and server under concurrent requests.
- [ ] Reject adding a character the user does not own or cannot access.
- [ ] Group history keeps turns and character identities separate from existing single-chat history.
- [ ] Director output contains only valid group members and respects scene boundaries.
- [ ] Failed creation leaves no partial records.
- [ ] RLS blocks anon and non-owner reads/writes.
- [ ] Mock mode does not call AI services or alter real wallet balances.
- [ ] Retried turn requests cannot duplicate messages or charges.
- [ ] Existing single-chat, diary, memory, album, archive, and account deletion/recovery behavior has regression coverage.

## Current scope and exclusions

This plan remains the acceptance contract. The schema and deterministic mock-turn RPCs are applied only to the connected test Supabase project; no AI calls or wallet charges were enabled. Database smoke tests were run in transactions and rolled back. The UI now reads and writes group data through Supabase, but still requires browser-level end-to-end verification.
