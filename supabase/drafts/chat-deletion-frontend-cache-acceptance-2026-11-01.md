# Chat deletion frontend cache acceptance — PR #200

## Scope

This checklist covers local browser state only. Backend RLS/RPC/worker acceptance remains separate. Server deletion success is authoritative; a failed delete must never create a local tombstone or hide local data.

## Implemented safeguards

- Per-user local tombstones are stored separately from transcript data for deleted cloud sessions and groups.
- Session restore from the main state store and per-user session cache filters tombstoned IDs.
- Cloud session hydration filters tombstones both after the initial list response and again after awaited message/profile requests, preventing stale in-flight sync from rehydrating deleted sessions.
- Pending chat-session sync checks tombstones before/after awaited parent/message writes.
- Group list hydration checks tombstones before rendering and again after member/preview requests.
- Successful group deletion clears its local group diary key, cancels queued diary-save timers and removes cached sync state.
- Group diary sync/save paths recheck tombstones so a late response cannot recreate local diary content after deletion.
- A `storage` event removes cached sessions/groups and navigates away in other tabs on the same browser origin.
- When a tab becomes visible/focused, a throttled (15-second minimum interval) ID-only check reconciles currently cached session/group parents against RLS-filtered active rows. No polling or transcript fetch is added by this check.
- If a cloud sync confirms the currently open single chat is gone, the UI routes back to the chat list.

## Browser acceptance still required

1. **Single chat — success:** Open the same account in two tabs. Delete a cloud single chat in tab A and confirm. Tab A removes it only after RPC success; tab B immediately removes it through the storage event and leaves the deleted conversation.
2. **Single chat — cancel/failure:** Cancel the confirmation or simulate RPC failure. No tombstone is written; no local cache is removed; the chat remains visible.
3. **Group chat — success:** Open the same group in two tabs with group diary data. Delete in tab A. Both tabs remove the group; the group diary localStorage key is removed; queued diary-save timers are cancelled; tab B leaves the deleted group.
4. **Stale session sync race:** Start a delayed `loadCloudChatSessions` request, delete that session before the delayed response completes, then release the response. The session must not reappear.
5. **Stale group list/diary race:** Start delayed group list/member/preview and diary sync requests, delete the group, then release the responses. The group and local diary must not reappear.
6. **Pending write race:** Start a session metadata/message sync or group diary save, delete the parent, and confirm the backend rejects post-delete writes while the client does not rehydrate local content.
7. **Cross-device reconciliation:** Keep a chat open on device B, delete it on device A, then foreground/focus device B. Its ID-only reconciliation must remove the session/group and leave the deleted view without fetching transcript content.
8. **Account isolation:** Switch accounts while reconciliation is in flight. A response for the previous UID must not remove or rewrite the new account's local chats.
9. **Local-only chat:** Deleting a non-cloud local-only chat must not create a cloud tombstone or affect other users/accounts.

## Encounter deletion regression cases

10. **Encounter diary visibility:** Read a diary row linked to an active encounter session, soft-delete the parent session, then verify the same owner can no longer SELECT that diary row during the 30-day retention period.
11. **Latest-settled read RPCs:** After deleting a settled encounter session, both `get_latest_settled_encounter_session` and `get_latest_settled_encounter_affinity` return no row for that session.
12. **Story carry-over endpoint:** Calling `story-session` with a deleted `sourceEncounterSessionId` returns 409 and does not create a Story session or relationship state. Race the endpoint against deletion; the database trigger remains the final parent-lock guard.
13. **Settlement race:** Race `settle_encounter_session` against `delete_chat_session_content`. If settlement gets the parent lock first, it completes before deletion; if deletion commits first, settlement rejects. No settlement/affinity write may commit after deletion.
14. **Pause/resume after deletion:** `set_encounter_session_lifecycle_state` rejects pause/resume when the parent session is deleted.
15. **Session-link trigger guards:** Inserts or updates to encounter lifecycle, encounter turns, evaluation jobs, and story relationship link rows referencing a deleted session are rejected under parent-first locking.
16. **Financial state remains:** The deletion guards do not remove settled charges/refunds, wallet transactions, or global per-user/per-character affinity state unless a separate product requirement explicitly changes that behavior.

## Static checks run

- Parsed all six inline JavaScript script blocks from the current PR #200 `index.html` with the JavaScript parser: all passed syntax parsing.
- Ran a small isolated helper simulation for tombstone mark/read/filter behavior: marking a session and group succeeds; filtering removes only the tombstoned session and preserves unrelated entries.
- These checks do not replace browser E2E. No browser click test has been run yet.
