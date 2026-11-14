# Migration 來源核對 — 2026-11-15 / PR #252

## 核對原則

- 本表只記錄 PR #252 分支新增的 migration；沒有改寫既有歷史 migration。
- `supabase/migrations/` 是正式 migration 來源；`supabase/drafts/` 仍是提案／證據／隔離測試資料，不可互相搬移。
- CI 的 disposable PostgreSQL replay 不代表 Hosted Supabase 已套用。
- 本輪沒有執行 Hosted Supabase DDL/DML，也沒有部署 Edge Function。

## PR #252 新增 migration

| Migration | 目的與邊界 | 目前測試證據 | Hosted 狀態 |
|---|---|---|---|
| `20261114130000_add_bounded_character_comment_reads.sql` | 新增 `get_character_comments_safe_page`；保留 whisper masking、作者／角色作者權限與公開／NSFW 可見性檢查；每頁最多 10 筆。 | Node source contract 已檢查 SECURITY DEFINER、遮蔽 helper、LIMIT 與 ACL；尚缺獨立 disposable PostgreSQL 行為 fixture。 | 未套用 |
| `20261114180000_group_ai_single_orchestrator.sql` | 群組單次 AI orchestration 的狀態欄位、reserve/complete/refund RPC、舊 mock RPC 撤權與錢包 ledger 冪等索引。 | Group chat workflow 在 disposable PostgreSQL 套用 migration，執行 transaction、rollback、concurrency、idempotency 情境。 | 未套用 |
| `20261114200000_batch_character_story_and_encounter_schedule_reads.sql` | 批次讀取作者角色最新故事、遭遇排程及查找最近 Story session；每次角色 ID 限制 1–10。 | Node source contract 已檢查 DISTINCT ON、ID 上限與 INVOKER／DEFINER；尚缺完整 disposable PostgreSQL 行為 fixture。 | 未套用 |
| `20261114230000_batch_group_list_previews.sql` | 以 owner-scoped RPC 一次取得最多 10 個群組的最新訊息預覽。 | Group chat workflow 在 disposable PostgreSQL 套用 migration，驗證擁有者、軟刪除群組、刪除訊息與 ID 上限。 | 未套用 |
| `20261115090000_batch_followed_author_latest_characters.sql` | 一次查詢最多 10 位作者；每位最多回傳 5 個公開、未刪除角色。 | Group chat workflow 建立隔離 fixture、套用 migration，驗證排序、私密／刪除隔離與作者 ID 上限。 | 未套用 |

## 尚需補足

1. 為 bounded comment page RPC 增加 disposable PostgreSQL fixture，驗證 whisper thread masking、作者／一般訪客、NSFW 與分頁上限。
2. 為 character story／Encounter schedule／existing Story session 三個 RPC 增加 disposable PostgreSQL 行為 fixture。Node source contract 不等於 SQL 執行驗證。
3. 在任何 Hosted migration 前，先核對該環境已套用版本、RPC 既有定義、RLS／ACL、依賴與回滾方式；不可只因 CI 綠燈就直接部署。

## 結論

PR #252 的 migration 檔案皆為新增來源，沒有為了瘦身改寫歷史 migration。部分 migration 已有 disposable PostgreSQL 行為測試；兩組讀取 RPC 目前仍以 source contract 為主，需補上隔離資料庫行為測試。所有 Hosted migration 狀態均維持「未套用」。
