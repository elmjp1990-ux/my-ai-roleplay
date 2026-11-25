# CSS Extraction Batch 3: Chat Layout (2026-11-25)

## Scope
- `chat-layout-shell.css`: shared full-bleed chat shell rules previously in `poyozz-chat-full-bleed-shared`.
- `chat-keyboard-viewport.css`: viewport height/layout rules and city location subtitle rules previously in `poyozz-chat-keyboard-viewport`.

## Preservation
- The style block contents were moved without changing selectors, declarations, or ordering.
- Inline style blocks were replaced at their original positions by stylesheet links.
- No JS, chat logic, AI behavior, theme, breakpoint, or data changes.

## Static deployment
- Added both files to the Vercel runtime allowlist.
- Added individual size budgets (1.5 KB and 1 KB); the global 1.5 MB budget is unchanged.
- Stylesheets are served as static runtime files; no URLs/assets embedded.

## Validation
- Pending PR CI and Preview visual checks (mobile/desktop chat, keyboard resize, single/group chat).
- Preview only; no Production, Supabase, or Edge Function deployment.
