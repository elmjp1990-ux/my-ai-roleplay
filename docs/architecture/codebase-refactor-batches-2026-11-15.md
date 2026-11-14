# PR #252 後續程式碼整理批次 — 2026-11-15

> 工作基底：`feat/group-ai-single-orchestrator`，依賴 PR #252 的第二批資料讀取與分頁修改。PR #252 目前仍為 Open；本文件記錄的是分支內容，不代表已合併、已部署或 Hosted Supabase 已更新。

## 第二批 — 減少剩餘資料請求

| 項目 | 狀態 |
|---|---|
| 喜愛作者最新公開角色批次 RPC | 已實作；每頁最多 10 位作者、每位最多 5 筆預覽 |
| 相簿／群組背景照片簽名網址批次化 | 已實作；共用 Signed URL Manager |
| 作者頁、角色立繪簽名網址請求 | 已整合共用批次管理器 |
| 第二批 CI | PR #252 先前的測試執行已通過；後續修改仍須以最新 HEAD 重跑 |

## 第三批 — 共用程式整理

| 項目 | 本輪結果 |
|---|---|
| AI Provider 共用傳輸層 | Story 單人、群組及五回合摘要共用 `openrouter-chat-completions.ts` |
| Provider 隱私路由 | 共用 `openrouter-provider-policy.ts` allowlist；關閉 fallback、要求 `data_collection: deny` |
| 重複格式化／驗證 | 摘要不再自行 fetch、建立 AbortController、解析回應或呼叫 normalize；統一交給共用 transport |
| 角色 Profile Worker | 保留專用 bounded streaming／response-size validation，但改用同一 provider allowlist |
| 舊 helper 清理 | 已確認摘要專用的 OPENROUTER_URL 常數不再需要並移除；不以名稱或搜尋結果推測其他 helper 無引用 |
| 高風險狀態處理 | 單人與群組退款／reconciliation 流程保持分開，因兩者的交易 RPC 與逾時語義不同，不做機械式合併 |

## 第四批 — 主程式模組化

已抽離或已在 PR #252 中維持獨立的低耦合畫面／技術模組：

- `city-map.js`
- `author-profile.js`
- `followed-authors.js`
- `comment-renderer.js`
- `custom-tag-picker.js`
- `memory-album.js`
- `notifications-screen.js`（本輪新增）

本輪新增通知畫面模組，保留主程式對通知讀取狀態與已讀操作的所有權；模組只負責畫面、10 筆漸進顯示及 observer 清理。

下一步先整理低風險資料讀取 adapter，建立穩定 query／cache／invalidation contract。聊天室、錢包、AI、親密度、手機、刪除與 RLS 不在一般模組化範圍內。

## 第五批 — SQL、文件與測試

| 項目 | 本輪結果 |
|---|---|
| Migration 來源核對 | 新增 `migration-source-audit-2026-11-15.md`；確認 PR #252 新增 migration，未改寫歷史 migration |
| SQL 測試證據 | 群組交易、群組預覽、喜愛作者批次 RPC 有 disposable PostgreSQL 情境；留言分頁與角色故事／遭遇排程讀取目前仍有 SQL 行為 fixture 待補，Node source contract 不等同 SQL 執行測試 |
| Draft 分類 | 新增 `supabase/drafts/README.md`，先分類已核對檔案；明確標示非全目錄盤點，未刪除或搬移任何草案 |
| CSS 條件式去重 | 掃描 `poyozz-ui.css` 與 index 內 13 個 style 區塊，共 1,059 個一般 rule blocks；相同條件上下文中沒有完整相同的可安全刪除規則。重複 selector 多為 cascade／主題／裝置差異，未自動刪除 |
| 行為測試 | 新增通知列表 10 筆分頁、篩選、observer dispose 測試；新增 OpenRouter transport Deno contract test |

## 不變更範圍

- 不處理錢包交易紀錄與錢包扣款流程。
- 不執行 Hosted Supabase migration，不部署 Edge Function。
- 不刪除未完成引用核對的 Draft。
- 不改寫高風險聊天室、錢包、AI、刪除、RLS 或 Storage 授權語義。
- 不以隱藏前端資料代替後端限量查詢；列表優化必須從查詢／RPC／Storage 請求來源限量。

## 驗收條件

1. 最新 HEAD 的所有相關 GitHub Actions 成功。
2. 靜態輸出 allowlist 包含新模組，部署檔案大小預算通過。
3. 最新 SQL 測試只在 disposable PostgreSQL 執行；Hosted 狀態另外核對。
4. 任何後續資料讀取層抽離，都必須保留查詢數量、資料筆數、快取失效及帳號切換保護測試。
