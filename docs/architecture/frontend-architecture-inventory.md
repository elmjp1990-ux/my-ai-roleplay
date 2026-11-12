# Frontend Architecture Inventory and Refactor Plan

> Baseline: `main` at `360f711d5a774c1bfac69d4704dba4a8cd9f770b` (PR #227 merge).
> Scope: inventory and safe refactor sequencing. This document does not authorize runtime behavior changes, hosted Supabase operations, data deletion, or Production deployment.

## 1. Current repository shape

Snapshot from the baseline commit:

- 383 tracked files in the recursive Git tree.
- `index.html`: 863,140 bytes and 13,390 lines.
- `index.html` contains 13 style blocks and 8 script tags.
- `scripts/`: 40 files.
- `supabase/drafts/`: 103 files.
- `supabase/migrations/`: 151 files.
- Root runtime currently includes `index.html`, `memory-capture.js`, the two generated WebP brand assets, and `encounter-default-scene.webp`.

The application is currently a large single-page HTML entry with inline application code and feature scripts. It is not safe to split it by mechanically moving arbitrary line ranges: many functions share classic-script global scope and depend on initialization order.

## 2. Confirmed responsibility hotspots

### 2.1 Chat render lifecycle is extended by assignment wrappers

The base render functions are declared in the main application code:

- `renderConversation()`: around line 7,835.
- `renderMessages()`: around line 8,057.
- `renderGroupConversation()`: around line 6,869.
- `renderChatOverlay()`: around line 8,335.
- `renderGroupChatOverlay()`: around line 7,337.

The memory-album feature script later replaces several function references:

- Around line 12,394, it saves `oldRenderConversation` and assigns a new `renderConversation` wrapper to apply memory-photo backgrounds.
- Around line 12,400, it wraps `renderGroupConversation` to apply group background state.
- Around line 12,409, it wraps `renderChatOverlay` to render the album overlay.
- Around line 12,420, it wraps `renderGroupChatOverlay` for the group album overlay.

The encounter feature script later installs another wrapper:

- Around line 12,934, `installEncounterRenderWrapper()` captures the then-current `renderConversation`.
- Around line 13,076, it also wraps `renderMessages()` so encounter dialogue beats survive message-only renders.
- It uses a DOMContentLoaded-aware installer and an `__encounterWrapped` guard.

This creates an implicit chain: the final behavior depends on which feature script installs first and which function reference each wrapper captures. A future change can accidentally bypass another feature's post-render behavior.

**Refactor target:** introduce a small, explicit render extension registry with named lifecycle hooks (for example: after single-chat render, after message render, after group-chat render, and overlay rendering). Feature modules register callbacks; the base render functions remain the owners of their own execution. Keep overlay rendering as an explicit renderer registry keyed by overlay type rather than replacing the whole function.

Do not implement this by simply moving current wrappers into separate files. First define hook order, idempotent registration, error isolation, and a testable contract.

### 2.2 Image compression has separate engines with overlapping mechanics

- `compressUploadImage(file, options)` is around line 6,022. It supports configurable edge/byte budgets and alpha-preserving WebP/PNG output; character and profile uploads call it with different presets.
- `compressMemoryImage(file)` is around line 12,276. It independently uses ImageBitmap/canvas/WebP, a 1,200px maximum side, a 450KB target, and a white canvas background.

These are not interchangeable policies: memory photos intentionally flatten onto white, while character/portrait uploads can preserve alpha.

**Refactor target:** one shared encoder with explicit presets/options for avatar, character primary image, character illustration, memory photo, and future scene assets. Preserve validation, output type, transparency behavior, dimensions, size budgets, error messages where user-facing, and cleanup of object URLs/ImageBitmap resources.

### 2.3 Signed URL/cache responsibilities are distributed

Character illustration refresh logic and memory-photo signed URL loading maintain separate state and call paths. Character video URLs have another cache/in-flight map. These use different buckets and expiration policies, so a universal fixed policy would be incorrect.

**Refactor target:** a shared low-level signed-URL manager accepting bucket, path, TTL/expiry safety margin, force-refresh, cache scope, and retry/invalidation policy. Keep feature-specific adapters and preserve the existing illustration retry guard, stale-request protection, and per-resource cache boundaries. Do not merge video lifecycle behavior into image behavior without separate evidence.

### 2.4 CSS is accumulated in multiple style blocks

The entry contains 13 style blocks, including late feature overrides and an encounter-specific final override block. Some late overrides are intentional compatibility fixes; selector text duplication alone is not proof that a rule is dead.

**Refactor target:** progressively separate tokens/base, shared components, feature styles, and responsive overrides. Remove a declaration only after checking computed style / responsive behavior and visual regression for the affected page.

### 2.5 Asset optimizer has two implementations

- Active workflow `.github/workflows/optimize-brand-assets.yml` runs `node scripts/optimize-brand-assets.mjs`.
- `scripts/optimize-brand-assets.py` also exists.

The Python file is a candidate for retirement only after checking all repository references, documentation, and manual workflows. Do not remove source PNG logos: the active optimizer uses them as source inputs while generated WebP files are runtime assets.

### 2.6 Supabase drafts and migrations need an index, not deletion

- `supabase/drafts/` has 103 files.
- `supabase/migrations/` has 151 files.

Create a registry that classifies draft artifacts as current/approved, superseded, exploratory, or historical. Migration history is immutable; this cleanup phase must not combine, rewrite, or delete migration files.

## 3. Proposed ownership map

This is a target ownership model, not a claim that these modules already exist.

| Area | Target ownership | Key boundaries |
| --- | --- | --- |
| Core/runtime | app bootstrap, state, routing, shared DOM/utilities | No feature-specific business rules |
| Chat | single-chat rendering, messages, history pagination, composer | Keep wallet/AI server contracts unchanged |
| Group chat | group list, group message rendering, member/scene UI | Group AI orchestration remains out of scope |
| Encounter | encounter presentation and dialogue progression | Uses chat lifecycle hooks; no duplicate base renderer |
| Memory album | photo upload, album UI, memory-photo backgrounds | Uses shared compression and signed-URL adapters |
| Characters | character editor, avatar/gallery, illustration display | Preserve private profile and storage policies |
| Wallet | wallet UI and client interaction with server-authoritative APIs | No pricing, charge, refund, or ledger changes |
| Affinity / phone | presentation and reads of existing state | No model, prompt, or state semantics changes |
| City map | map, location panels, encounter entry | Preserve location/schedule validation |
| Account | auth UI, deletion flows, profile | Preserve deletion/privacy lifecycle |
| Styles | tokens, base, components, feature, responsive | No visual change during structural moves |
| Scripts/tests | build, asset optimization, regression checks | Runtime build allowlist stays explicit |
| Supabase | migrations, functions, drafts, operations | Historical migrations immutable |

## 4. Safe implementation sequence

1. **Inventory and contracts (this phase):** document module ownership, render hook points, global dependencies, script order, and test coverage. No runtime changes.
2. **Render lifecycle registry:** add tests first; introduce explicit hook registration; migrate memory-album and encounter extensions one at a time; remove wrappers only after parity tests.
3. **Shared image encoder:** implement configurable presets; migrate one upload flow at a time; retain old helper adapters until tests pass.
4. **Signed URL manager:** centralize only the common cache/in-flight/expiry primitives; keep bucket-specific adapters and retry policies.
5. **Feature JS extraction:** extract one low-coupling feature at a time, preserving classic-script/global compatibility initially. Introduce modules only with an explicit public interface and dependency order.
6. **CSS extraction:** split by layers/features and run responsive visual regression after each move.
7. **Tooling and draft registry:** verify active workflows and references before retiring duplicate scripts; classify drafts without deleting migration history.

## 5. Static deployment constraint

`scripts/build-vercel-static.mjs` currently copies exactly five runtime files into `dist`:

- `index.html`
- `memory-capture.js`
- `LOGO_WEBICON.webp`
- `LOGO_WEBLOGO.webp`
- `encounter-default-scene.webp`

`scripts/test-vercel-static-output.mjs` asserts the exact file allowlist, per-file budgets, total output budget, and statically discoverable local asset references. Any extracted runtime JS/CSS file must be added to both the build allowlist and test expectations, with reference checks retained. Dynamically constructed asset paths still need runtime/browser validation.

## 6. Non-regression boundaries

The refactor must not change:

- AI provider/model selection, prompt content, turn execution, refusal/refund behavior, or summary generation.
- Wallet charge/refund, membership entitlement, ledger, or transaction semantics.
- Affinity, phone-event, memory-summary, or suggested-reply semantics.
- Chat/account deletion, retention, RLS, access-control, or privacy behavior.
- Encounter schedule validation and server-authoritative session creation.
- Existing Supabase migrations or hosted project state.

No hosted Supabase migrations, data deletion, Storage object deletion, bucket policy changes, or manual Production deployment are part of this work.

## 7. PR acceptance checklist

- [ ] Base branch is the latest `main`; record exact base SHA.
- [ ] Each refactor is isolated in its own PR and does not mix unrelated feature work.
- [ ] Tests cover hook ordering, duplicate registration, failure isolation, and behavior parity.
- [ ] Existing regression tests for chat history, wallet/refund, encounter, deletion, phone/affinity, and storage refresh remain passing.
- [ ] Vercel static output allowlist and asset-reference checks are updated for extracted runtime files.
- [ ] CI passes and Preview deployment corresponds to the exact PR head SHA.
- [ ] Browser E2E is explicitly marked pending when Supabase egress restriction prevents real Storage/API verification.
- [ ] User reviews and authorizes merge separately; main merge may auto-trigger Vercel Production via Git integration.

## 8. Immediate next step

Complete a line-level dependency map for the chat render extension points and add contract tests before changing runtime code. The first code PR should only introduce the render lifecycle registry and migrate one feature extension at a time, with no UI or business behavior changes.
