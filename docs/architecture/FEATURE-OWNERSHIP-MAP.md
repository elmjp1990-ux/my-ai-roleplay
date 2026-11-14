# POYOZZ Feature Ownership Map

> Status: inventory of the current implementation and proposed ownership boundaries.
> Baseline: `main` at `c3ae257e2e4bbe9c27661bc9b10d99a7e6f511d2` (PR #242 merged; includes #240).
> This document is a navigation guide, not permission to change backend semantics. File/line locations can drift; search by the named function when line numbers change.

## How to find the right place

1. Start with the feature table below.
2. For a screen or component, find the current renderer in `index.html` or the extracted presentation module.
3. For data fetching or writes, trace the named frontend function to its Supabase table/RPC or Edge Function. Do not change a UI renderer to solve a backend authorization/transaction problem.
4. For media, use the shared compression and signed-URL services rather than adding a new implementation.
5. Before changing a high-risk flow, update its contract/regression tests and inspect the corresponding migration/RLS/Edge Function.

## Current implementation map

| Feature / user-visible area | Current frontend entry points | Current data / backend boundary | Proposed long-term home | Risk |
|---|---|---|---|---|
| App boot, route, global shell | `index.html`: `freshState`, `load`, `persist`, `parseRoute`, `go`, `renderShell`, `render` | Browser state/local storage; auth initialization | `src/core/` | Medium |
| Explore / home / character cards | `index.html`: `renderHome`, `renderGrid`, `renderDetail`, `loadPublicCharacterRows`, `loadPublicSupabaseCharacters`; `list-pagination.js`: shared 20-row Explore paging; `city-map.js`: `renderCityMapMVP` | Public character/profile reads; public illustration metadata and signed URLs | `features/explore/` + `features/characters/` | Medium |
| Character create/edit and AI settings | `index.html`: `renderCreate`, `renderEditor`, `renderAI`, `saveSupabaseCharacter`, `renderCharacterIllustrationGallery`, `uploadCharacterIllustrationDataUrl`, `compressUploadImage` | Character/profile writes; illustration Storage; private character info; AI profile organization worker | `features/characters/` | Medium–High |
| Character media / video | `index.html`: `getCharacterIllustrationSignedUrl`, `getCharacterVideoSignedUrl`, `hydrateCharacterVideo`, `releaseCharacterVideo`; shared modules below | Supabase Storage buckets and metadata; visibility/ownership checks | `services/media/` + character feature adapters | High (privacy/storage) |
| Single Story chat | `index.html`: `startChat`, `renderConversation`, `renderMessages`, `formatMessage`, `conversationSuggestionsHTML`, `renderPhoneModal` | `chat_sessions`, `chat_messages`; `supabase/functions/chat-turn/index.ts`; shared prompt/context and memory summary | `features/chat/single/` | Very high |
| Group chat | `index.html`: `groupOpen`, `groupLoadOlderMessages`, `renderGroupConversation`, `groupSendTurn`, `renderGroupChatOverlay`, `groupDiaryStorageKey`, `syncGroupDiaryCloud`, `saveGroupDiaryCloudNow` | `chat_groups`, members, turns/messages, diary; `group-chat-turn` Edge Function; shared character AI profile formatter and speaker parser; service-role reserve/complete/refund RPCs and group usage ledger | `features/chat/group/` + `features/memory/group-diary/` | Very high |
| Chat list / history / deletion | `index.html`: `renderChatListPage`, `loadCloudChatSessions`, `loadCloudSessionMessages`, `saveChatSessionSafely`, `reconcileDeletedCloudChatParents`; `list-pagination.js`: shared 10-row chat lists and 5-message history pages | Chat tables, tombstones, deletion RPCs, purge workers and retention migrations | `features/chat/history/` | Critical |
| Encounter mode | `encounter-scene.js` presentation lifecycle; `index.html`: `createEncounterSession`, `findResumableEncounterSession`, `setEncounterLifecycleState` | `encounter-session`, `encounter-session-state`, `encounter-turn`, lifecycle/evaluation RPCs and migrations | `features/encounter/` | Very high |
| Memory album / photos | `memory-album.js`; `memory-capture.js`; `index.html`: `renderChatAlbumPage`, `addMemory`, `loadStoryMemorySummary` | `chat_memory_photos`, memory summary RPCs, expiry worker and Storage | `features/memory/album/` | High |
| Phone state / affinity / suggestions | `index.html`: `renderPhoneModal`, `normalizePhoneNoticeRows`, `readPhoneNoticeRows`, `conversationSuggestionsHTML`; chat-turn shared context | Story phone state, relationship batch/evaluation records and summary usage; authoritative updates in backend | `features/chat/context/` + `features/relationship/` | Very high |
| Authors / follows / comments | `author-profile.js`, `followed-authors.js`, `comment-renderer.js`; `index.html`: `renderAuthor`, `renderFollowedAuthors`, `loadPublicAuthorCharacterPage`, `loadPublicAuthorLatestCharacters`, `renderComments`, `loadCloudComments`, `refreshAuthorFollowState` | `author_follows`, public profiles, comments and related RPC/RLS | `features/social/` | Medium |
| Wallet / shop / check-in / ad turns | `index.html`: `wallet`, `walletPreflight`, `loadWalletLedger`, `renderShop`, `renderDailyCheckinMarkup`, `refreshWalletBalance` | Wallet accounts/transactions, chat-turn charge reserve/settle/refund functions, check-in RPCs and ad verification | `features/wallet/` | Critical |
| Account / profile / notifications / login | `index.html`: `loginWithGoogle`, `requireLogin`, `renderProfile`, `renderNotifications`, `saveSupabaseProfile` | Supabase Auth, profiles, notification tables/RPCs, account status and deletion worker | `features/account/` | Critical |
| Shared image compression | `image-compression.js` via `window.PoyozzImageCompression`; adapters in `index.html` and `memory-album.js` | Browser Canvas/ImageBitmap only; upload destination remains caller-owned | `services/media/image-compression/` | Medium |
| Signed URL cache / refresh | `signed-url-manager.js` via `window.PoyozzSignedUrlManager`; adapters in `index.html` | Storage signed URLs; caller retains bucket/path/authorization ownership | `services/media/signed-urls/` | High |
| Chat render extension points | `chat-render-lifecycle.js` via `window.PoyozzChatRenderLifecycle`; registrations in `memory-album.js`, `encounter-scene.js` | Presentation lifecycle only; no data ownership | `shared/chat-render-lifecycle/` | Medium |
| Custom tag picker | `custom-tag-picker.js`; thin app adapter in `index.html` | Character form state and existing tag validation/save logic remain app-owned | `features/characters/tag-picker/` | Low |
| Build, static output, tests | `scripts/`, `.github/workflows/`, `vercel.json` | Static asset allowlist, runtime asset scan, CI contract checks | `tooling/build/`, `tooling/tests/` | Medium |

## Extracted frontend modules (already present)

| File | Responsibility | What it must not own |
|---|---|---|
| `memory-capture.js` | Memory excerpt construction and serialized session-save coordination | UI, wallet, Storage policy |
| `chat-render-lifecycle.js` | Ordered, error-isolated render extension hooks | Chat data or business rules |
| `image-compression.js` | Browser-side image decode/resize/compress and resource cleanup | Upload path, Storage policy, business-specific authorization |
| `signed-url-manager.js` | Signed URL cache, expiry buffer, in-flight dedupe and invalidation | Bucket policy, access decisions, object deletion |
| `city-map.js` | City map presentation using injected dependencies | Persistence, authentication, chat/encounter creation rules |
| `followed-authors.js` | Followed-author presentation | Follow mutations or RLS |
| `author-profile.js` | Author profile presentation | Follow mutations or profile authorization |
| `comment-renderer.js` | Comment presentation | Comment fetch/mutations or privacy filtering |
| `custom-tag-picker.js` | Custom tag picker rendering and local event binding | Tag persistence or character save |
| `list-pagination.js` | Shared page-size configuration, IntersectionObserver lifecycle, and duplicate-safe page merging for Explore, author profiles, chat lists, Encounter memories, and chat history | Feature-specific queries, ordering, filtering, authorization, or persistence |
| `memory-album.js` | Memory album UI and render lifecycle adapters | Chat/wallet transaction rules |
| `encounter-scene.js` | Encounter visual-novel presentation | Encounter authorization, lifecycle settlement, billing |

## Backend ownership map

| Concern | Current location(s) | Ownership rule |
|---|---|---|
| Story AI turn orchestration | `supabase/functions/chat-turn/index.ts`; `supabase/functions/group-chat-turn/index.ts` | Authentication, ownership, prompt assembly, one-call provider orchestration, turn state, and downstream coordination stay server-authoritative. Group AI selects 1–3 speakers from the roster in one model call. |
| Shared AI prompt/context | `supabase/functions/_shared/prompt-context.ts`, `prompt-variables.ts`, `character-ai-profile-prompt.ts`, `group-speaker-output.ts`, `openrouter-chat-completions.ts`, `story-memory-summary.ts` and related shared files | Single and group chat reuse character AI-profile formatting and the same privacy-restricted OpenRouter request client; group output is parsed into explicit speaker IDs. Keep model/prompt behavior separate from generic frontend refactors. |
| Encounter session and turns | `supabase/functions/encounter-session/`, `encounter-session-state/`, `encounter-turn/`, plus encounter shared helpers | Server validates session ownership, current lifecycle, schedule and turn eligibility. |
| Character AI profile organization | `supabase/functions/character-profile-organization-worker/`, `supabase/functions/_shared/character-profile-organization.ts` | Background derived-data workflow; distinct from user-facing character form persistence. |
| Chat retention/purge | `supabase/functions/purge-chat-deletions/`, `supabase/functions/_shared/chat-deletion-worker.ts` | Retention, tombstones and purge are backend-owned; do not replace with frontend deletion. |
| Memory photo expiry | `supabase/functions/expire-memory-album-photos/` | Server-side expiry and object cleanup. |
| Account deletion | `supabase/functions/account-deletion-worker/` and `supabase/functions/_shared/account-deletion-worker.ts` (where present) | Critical lifecycle; worker, migrations, Auth Admin and preservation rules must be reviewed together. |

## Data and schema ownership

- `supabase/migrations/`: ordered database history. Do not rename, reorder, squash or relocate historical migrations as a cosmetic cleanup.
- `supabase/drafts/`: proposals, replay fixtures, audits and superseded references. Each file needs a status (active draft / superseded / evidence / test fixture) before deletion or promotion. A draft is not automatically deployed.
- `supabase/functions/`: deployable Edge Function source. `_shared/` is backend-only shared code, not frontend shared code.
- `scripts/`: tests, audits, build helpers and local replay harnesses. Keep test fixtures distinct from deployable application code.
- `docs/`: durable architecture, runbooks, feature plans and decisions.

## Change routing: where to start

| If the requested change is… | Start here | Also inspect |
|---|---|---|
| Change page layout or visual component | Current renderer / extracted presentation module | Feature CSS, render lifecycle hooks, screenshot/browser regression |
| Change what data appears or how it is fetched | Feature data-loading function in `index.html` | Table/RPC, RLS policy, cache invalidation, egress impact |
| Change who can read/write something | Edge Function / RPC / RLS migration | Frontend error state and authorization regression tests |
| Change AI personality, memory, model or prompt | `chat-turn/index.ts` and `supabase/functions/_shared/` | Model selection, cost logs, refusal/refund, prompt and summary tests |
| Change chat turn charge/refund | Wallet RPC migrations and `chat-turn` transaction path | Idempotency, duplicate request, late AI reply, wallet ledger regression |
| Change media quality or upload size | `image-compression.js` and its feature adapter | MIME/alpha handling, output budget, Storage upload contract |
| Change media URL refresh | `signed-url-manager.js` and feature adapter | TTL, owner/path isolation, expiry, stale request races |
| Change deletion or retention | Relevant deletion Edge Function + migration + worker | RLS, Storage object lifecycle, financial/audit evidence, retry/concurrency |
| Change a feature's style | Its style block in `index.html` until CSS extraction is complete | Duplicate overrides, mobile breakpoints, encounter/map mode collisions |

## Rules for future modularization

1. Extract one feature per PR. Prefer presentation-only code first; use explicit dependency injection and avoid introducing new hidden globals.
2. A feature module owns its rendering and local interactions; a service owns reusable technical behavior; a backend function owns authorization and server-side business invariants.
3. Do not move Supabase queries into generic UI helpers. A later data-access layer should be introduced only with explicit contracts and tests, not as a mechanical move.
4. Do not split single/group chat, wallet, affinity/phone, deletion, AI or privacy semantics without characterization tests and a dedicated review.
5. Preserve script load order and static deployment completeness. Update `vercel.json` allowlist, static output tests, runtime asset scan, file-size budgets and workflow path filters for each new browser asset.
6. CI and Vercel Preview do not prove real browser behavior or hosted Supabase E2E. Supabase egress restrictions must be treated as a separate verification limitation.
7. Keep the current global-script deployment model until a separately reviewed build/ES-module migration is approved. Do not introduce a partial bundler conversion during feature extraction.


## Verified dependency map — first pass

> Verification baseline: main at c3ae257e2e4bbe9c27661bc9b10d99a7e6f511d2 (PR #242). Function names are stable search anchors; line numbers are intentionally omitted. This is a verified first pass, not a complete static call graph.

### Core state, startup and routing

| Layer | Current owner | Dependency / boundary | Regression coverage |
|---|---|---|---|
| Browser client | index.html initializes window.mySupabase from the project URL and publishable key | One global Supabase client is shared by the entire inline application | Static output and runtime asset workflows |
| Global state | freshState, load, migrateOld, persist, compactLocalStateForQuota | state is the shared owner for account, characters, sessions, route-adjacent UI and caches; localStorage keys include personax-v3 and per-user chat/tombstone namespaces | scripts/test-chat-history-lazy-loading.mjs |
| Auth bootstrap | syncSupabaseUser, loadSupabaseProfileAndWallet, loginWithGoogle | Supabase Auth state listener; profiles, wallet_accounts; RPCs get_account_deletion_status, save_my_profile, get_my_private_profile_data, ensure_wallet_account | Account deletion and wallet tests; no isolated account service yet |
| Routing/render shell | parseRoute, go, back, renderShell, render | Global route and state; many feature renderers are dispatched from the same main render path | Chat render lifecycle tests and feature-specific UI contracts |
| Global interaction delegation | index.html document-level [data-action] click/input handlers | Many features share one delegated event surface; action names are effectively a cross-feature interface | Feature-specific contract tests; this is a high-coupling extraction boundary |

**Architecture finding:** core state, auth bootstrap, routing, UI event delegation and most data access still live in one global script. Extracted feature files are not yet independently bootstrapped feature packages.

### Feature-to-data dependency matrix

| Feature | Frontend flow | Verified tables / RPC / Edge boundary | Tests / verification anchors |
|---|---|---|---|
| Explore and public character discovery | renderHome, renderGrid, renderDetail, loadPublicCharacterRows, loadPublicSupabaseCharactersImpl | Reads characters, public_profiles, character_stories; public illustration metadata from character_illustrations; turn counts via get_character_turn_counts | scripts/test-runtime-egress-optimizations.mjs, scripts/test-public-comment-hydration-cache.mjs, scripts/test-public-illustration-lazy-loading.mjs |
| Character create/edit | renderCreate, renderEditor, saveSupabaseCharacter, saveEncounterScheduleDescription | Writes characters, character_private_info, character_schedule_descriptions, character_stories; gallery metadata in character_illustrations; enqueues derived-profile work through enqueue_character_profile_organization | scripts/test-phone-notice-presentation.mjs, scripts/test-character-ai-profile-contract.mjs, scripts/test-character-profile-organization-queue.sql |
| Character AI-derived profile | Character save computes deterministic changed-field categories; browser does not call the model directly | character-profile-organization-worker and _shared/character-profile-organization.ts; queue/usage tables and claim/complete RPCs are separate from ordinary character save | scripts/test-character-ai-profile-contract.mjs, scripts/test-character-profile-organization-queue.sql |
| Single Story chat | startChat, createStorySession, saveChatSessionToCloud, loadCloudChatSessions, loadCloudSessionMessages, saveChatSessionSafely, executePendingChatTurn | Tables chat_sessions and chat_messages; session creation via story-session; turn generation via chat-turn; server-side reservation/settlement/refund RPCs own billing | scripts/test-chat-history-lazy-loading.mjs, scripts/test-chat-turn-wallet-refund.sql, scripts/test-dual-model-memory-summary.mjs, scripts/test-story-phone-and-suggestions-regression.mjs |
| Group chat | groupCreate, groupOpen, groupLoadOlderMessages, renderGroupConversation, groupSendMock | Tables chat_groups, chat_group_scenes, chat_group_members, chat_group_turns, chat_group_messages, chat_group_turn_charges, chat_group_diary; creation RPC create_chat_group; send RPC append_chat_group_mock_turn; initial history is capped at 50 and older pages use a created_at + sequence_no + id keyset cursor | scripts/test-runtime-egress-optimizations.mjs (bounded initial page, stable cursor, UUID tie-break, no gaps/duplicates, overlapping-page dedupe, group/account-switch guard, scroll anchoring) |
| Encounter mode | city-map.js calls the app adapter; createEncounterSession, findResumableEncounterSession, setEncounterLifecycleState, executePendingChatTurn | Edge Functions encounter-session, encounter-session-state, encounter-turn; tables include chat_sessions and encounter_session_lifecycle; service RPCs include create_encounter_session_with_lifecycle, set_encounter_session_lifecycle_state, reserve_encounter_chat_turn | scripts/test-encounter-chat-mode-guard.mjs, scripts/test-encounter-schedule-parser.mjs, scripts/test-story-turn-affinity-phone-events.sql |
| Chat history and deletion | loadCloudChatSessions, loadCloudSessionMessages, saveChatSessionSafely, reconcileDeletedCloudChatParents | Session/message data plus local tombstones; backend retention via purge-chat-deletions and _shared deletion workers; Storage cleanup uses durable job RPCs | scripts/test-chat-history-lazy-loading.mjs, scripts/test-chat-storage-api-retry-e2e.ts, scripts/test-deletion-concurrency.sh |
| Memory album and photos | memory-album.js, memory-capture.js, renderChatAlbumPage, addMemory | chat_memory_photos plus personax-memory-photos Storage; expiry worker expire-memory-album-photos; group diary sync uses chat_group_diary | scripts/test-image-compression.mjs, scripts/test-media-asset-optimization.mjs |
| Story relationship, phone and suggestions | loadStoryRelationshipState, conversationSuggestionsHTML, renderPhoneModal, loadStoryMemorySummary | chat-turn generates turn envelope; read RPCs include get_story_relationship_state, get_story_phone_state, get_story_phone_events, get_story_world_state, get_story_memory_summary / get_story_memory_summaries; summary worker is _shared/story-memory-summary.ts | scripts/test-story-phone-and-suggestions-regression.mjs, scripts/test-dual-model-memory-summary.mjs, scripts/test-story-turn-affinity-phone-events.sql |
| Wallet / ledger | wallet, walletPreflight, refreshWalletBalance, loadWalletLedger, renderShop | wallet_transactions read; ensure_wallet_account and get_my_wallet_transaction_character_names; authoritative single-chat charge/refund is server-side in chat-turn; group billing is atomic in append_chat_group_mock_turn | scripts/test-chat-turn-wallet-refund.sql and group egress regression test |
| Social / authors / comments | renderAuthor, renderFollowedAuthors, renderComments, loadCloudComments, refreshAuthorFollowState | author_follows, public_profiles, character_comment_likes; safe comment read via get_character_comments_safe | scripts/test-public-comment-hydration-cache.mjs |
| Account deletion | Account UI and status reads remain in index.html; backend worker is separate | account-deletion-worker uses lease/fencing RPCs and Auth Admin, but current source has ACCOUNT_DELETION_EXECUTION_ENABLED = false and returns 503 before destructive work | scripts/test-account-deletion-character-preservation-draft.mjs, supabase/functions/_shared/account-deletion-worker.test.ts |
| Shared media services | image-compression.js, signed-url-manager.js plus feature adapters | Compression is browser-only; signed URL manager caches URLs but callers still choose bucket, object path, authorization and deletion behavior | scripts/test-image-compression.mjs, scripts/test-character-illustration-signed-url-refresh.mjs, scripts/test-media-asset-optimization.mjs |

### Verified implementation gaps and important distinctions

1. **Group chat is currently a persisted mock-turn flow, not live group AI.** groupSendMock() calls append_chat_group_mock_turn; the corresponding migration describes deterministic mock turns and the group billing migration says the AI provider is not integrated. PR #242 now bounds groupOpen() to the newest 50 non-deleted messages and adds on-demand keyset pagination for older history using created_at + sequence_no + id, preserving chronological display, deduplicating overlaps, guarding group/account switches, and anchoring scroll position. The synthetic 1,000-row fixture verifies 20 complete pages with deterministic ordering and no gaps/duplicates; local-only CI also passed. Real hosted Supabase/browser E2E remains unverified while the project is restricted. Do not describe the planned group AI director/character-card orchestration as implemented.
2. **Encounter turn is currently a demo reply, not live AI.** encounter-turn/index.ts explicitly documents that no real AI provider is connected. It reserves billing and persists encounter turn evidence, but does not itself run the whole-session evaluator or call settle_encounter_session.
3. **Encounter evaluation has database queue scaffolding but no verified Edge evaluator worker in the current function inventory.** Migrations define enqueue/claim/settlement RPCs; do not claim affinity settlement is fully automated until a real worker and its scheduling/acceptance are located and verified.
4. **Account deletion execution is deliberately disabled.** The worker's compile-time kill switch is false; do not remove it or treat account deletion as end-to-end active during unrelated refactors.
5. **Single Story AI is a separate live provider path.** chat-turn/index.ts pins deepseek/deepseek-v4-flash-20260423; _shared/story-memory-summary.ts pins openai/gpt-oss-20b with a five-turn summary interval. Preserve these model and prompt boundaries in unrelated module extraction.
6. **Wallet UI preflight is not the billing authority.** walletPreflight() is a client-side UX gate; reservation, settlement, refunds and idempotency remain backend/RPC-owned. Never move or duplicate these rules into the browser.
7. **Feature modules are currently mixed-granularity.** Some extracted files own presentation only, while memory-album.js also owns local upload/UI coordination. Do not assume all current modules are pure renderers; inspect their public API before reuse.

### Recommended extraction order after this dependency pass

1. Core/shared helpers with no Supabase or financial side effects (formatters, validators, small DOM helpers) after confirming call sites.
2. Low-coupling presentation-only sections still inside index.html, each with one contract test and static-output/asset updates.
3. Feature-specific read adapters only after a stable query contract and cache invalidation contract exist.
4. Keep Story/Encounter/Group AI, wallet, affinity/phone, retention, account deletion, RLS and Storage authorization out of general extraction until dedicated characterization tests and separately approved implementation plans exist.


## Known current-state caveat

This is a source-navigation map, not yet a complete dependency graph. `index.html` still owns many cross-feature functions and direct Supabase calls. Before moving any feature, trace the exact call graph, shared state, event listeners, data queries and tests for that feature. The proposed `src/` directory layout is a destination model, not a claim that these folders already exist.
