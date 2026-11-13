# POYOZZ Feature Ownership Map

> Status: inventory of the current implementation and proposed ownership boundaries.
> Baseline: `main` at `f50b45997f1842dfa11d2f6fba4f5237fc50158e` (PR #240 merged).
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
| Explore / home / character cards | `index.html`: `renderHome`, `renderGrid`, `renderDetail`, `loadPublicCharacterRows`, `loadPublicSupabaseCharacters`; `city-map.js`: `renderCityMapMVP` | Public character/profile reads; public illustration metadata and signed URLs | `features/explore/` + `features/characters/` | Medium |
| Character create/edit and AI settings | `index.html`: `renderCreate`, `renderEditor`, `renderAI`, `saveSupabaseCharacter`, `renderCharacterIllustrationGallery`, `uploadCharacterIllustrationDataUrl`, `compressUploadImage` | Character/profile writes; illustration Storage; private character info; AI profile organization worker | `features/characters/` | Medium–High |
| Character media / video | `index.html`: `getCharacterIllustrationSignedUrl`, `getCharacterVideoSignedUrl`, `hydrateCharacterVideo`, `releaseCharacterVideo`; shared modules below | Supabase Storage buckets and metadata; visibility/ownership checks | `services/media/` + character feature adapters | High (privacy/storage) |
| Single Story chat | `index.html`: `startChat`, `renderConversation`, `renderMessages`, `formatMessage`, `conversationSuggestionsHTML`, `renderPhoneModal` | `chat_sessions`, `chat_messages`; `supabase/functions/chat-turn/index.ts`; shared prompt/context and memory summary | `features/chat/single/` | Very high |
| Group chat | `index.html`: `groupOpen`, `renderGroupConversation`, `renderGroupChatOverlay`, `groupDiaryStorageKey`, `syncGroupDiaryCloud`, `saveGroupDiaryCloudNow` | `chat_groups`, members, turns/messages, diary; group RPCs and billing/turn evidence | `features/chat/group/` + `features/memory/group-diary/` | Very high |
| Chat list / history / deletion | `index.html`: `renderChatListPage`, `loadCloudChatSessions`, `loadCloudSessionMessages`, `saveChatSessionSafely`, `reconcileDeletedCloudChatParents` | Chat tables, tombstones, deletion RPCs, purge workers and retention migrations | `features/chat/history/` | Critical |
| Encounter mode | `encounter-scene.js` presentation lifecycle; `index.html`: `createEncounterSession`, `findResumableEncounterSession`, `setEncounterLifecycleState` | `encounter-session`, `encounter-session-state`, `encounter-turn`, lifecycle/evaluation RPCs and migrations | `features/encounter/` | Very high |
| Memory album / photos | `memory-album.js`; `memory-capture.js`; `index.html`: `renderChatAlbumPage`, `addMemory`, `loadStoryMemorySummary` | `chat_memory_photos`, memory summary RPCs, expiry worker and Storage | `features/memory/album/` | High |
| Phone state / affinity / suggestions | `index.html`: `renderPhoneModal`, `normalizePhoneNoticeRows`, `readPhoneNoticeRows`, `conversationSuggestionsHTML`; chat-turn shared context | Story phone state, relationship batch/evaluation records and summary usage; authoritative updates in backend | `features/chat/context/` + `features/relationship/` | Very high |
| Authors / follows / comments | `author-profile.js`, `followed-authors.js`, `comment-renderer.js`; `index.html`: `renderAuthor`, `renderFollowedAuthors`, `renderComments`, `loadCloudComments`, `refreshAuthorFollowState` | `author_follows`, public profiles, comments and related RPC/RLS | `features/social/` | Medium |
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
| `memory-album.js` | Memory album UI and render lifecycle adapters | Chat/wallet transaction rules |
| `encounter-scene.js` | Encounter visual-novel presentation | Encounter authorization, lifecycle settlement, billing |

## Backend ownership map

| Concern | Current location(s) | Ownership rule |
|---|---|---|
| Story AI turn orchestration | `supabase/functions/chat-turn/index.ts` | Authentication, session ownership, prompt assembly, provider call, turn state, and downstream coordination stay server-authoritative. |
| Shared AI prompt/context | `supabase/functions/_shared/prompt-context.ts`, `prompt-variables.ts`, `story-memory-summary.ts` and related shared files | Keep model/prompt behavior separate from generic frontend refactors. |
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

## Known current-state caveat

This is a source-navigation map, not yet a complete dependency graph. `index.html` still owns many cross-feature functions and direct Supabase calls. Before moving any feature, trace the exact call graph, shared state, event listeners, data queries and tests for that feature. The proposed `src/` directory layout is a destination model, not a claim that these folders already exist.
