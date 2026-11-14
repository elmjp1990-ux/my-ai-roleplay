# `supabase/drafts/` 分類索引

本目錄不是可直接部署的 migration 目錄。**任何草案都不得因為檔名含有 SQL、看起來完整或曾在測試中執行，就直接套用到 Hosted Supabase。**

本索引是第一輪已核對檔案的分類，不宣稱已完整列出目錄內所有檔案。新增或移動草案時，必須同步更新本索引。

## 分類規則

| 分類 | 意義 | 可否部署 |
|---|---|---|
| Active proposal | 仍在討論／待安全審查的功能提案 | 不可 |
| Design / contract | 架構設計、JSON Schema、來源登錄或驗證規格 | 不可直接部署 |
| Evidence / snapshot | 唯讀結構快照、來源證據、稽核結果 | 不可 |
| Disposable fixture / replay | 僅供本機或 CI 隔離資料庫重播的 SQL、測試資料與 replay harness | 僅限隔離測試 |
| Superseded | 已被更完整或更新的提案取代 | 不可；保留歷史說明 |
| Historical proposal | 已有後續實作，但尚未完成逐項差異核對的早期提案 | 不可；先比對再封存 |

## 已核對檔案

| 檔案 | 分類 | 核對結果／後續處理 |
|---|---|---|
| `character-turn-count-parent-delete-filter-proposal.sql` | Superseded | 檔案內明確指出已被 `chat-deletion-cumulative-turn-statistics-proposal.sql` 取代；不可單獨升級或執行。 |
| `chat-deletion-cumulative-turn-statistics-proposal.sql` | Active proposal | PR #200 的累計角色回覆數保留提案；檔案要求先完成 migration provenance、版本衝突與精確 local Supabase CLI replay。不可套用 Hosted。 |
| `group-chat-core-schema.sql` | Historical proposal | 初期 GROUP-01 schema 草案；目前群組核心 schema 已有後續 migration。仍需逐表／欄位／constraint 比對後才能標記完全 superseded，暫不刪除。 |
| `account-deletion-worker-atomic-lease.sql` | Disposable fixture / replay | 檔案明確禁止套用 Hosted；僅供 disposable schema CI fixture。正式 migration 來源與歷史 profiles/characters baseline 必須分開核對。 |
| `replay-local-security-drafts.sql` | Disposable fixture / replay | 合成 current-state schema 的本機重播入口；明確使用 transaction rollback，不是歷史 migration replay，也不是 Hosted 部署指令。 |
| `current-state-schema-catalog-manifest-2026-11-02.md` | Evidence / snapshot | 2026-11-02 測試專案唯讀 schema catalog；包含人工／測試環境 drift，不能當成乾淨 migration baseline。 |
| `chat-turn-validation-matrix.md` | Design / contract | 錢包 chat-turn 測試規格；文件自述尚未執行，僅能在 disposable Supabase 環境測試。 |
| `character-profile-organization-queue-design-2026-11-07.md` | Design / contract | 角色 AI 衍生資料佇列設計紀錄；實際 migration、worker 與 hosted 部署狀態須以 GitHub／部署紀錄為準。 |
| `character-ai-profile-v1.schema.json` | Design / contract | AI 衍生角色 Profile 的 JSON 輸出驗證契約，不是 migration。 |
| `character-ai-profile-source-registry-v1.json` | Design / contract | Profile 來源欄位與證據登錄，需與 schema、worker validator 一起維護。 |

## 安全整理規則

1. 不刪除任何 SQL 草案，除非已確認沒有 replay script、CI workflow、文件或其他草案引用它。
2. 不把 `supabase/drafts/` 的 SQL 搬入 `supabase/migrations/`；正式 migration 必須重新核對歷史版本、現有 schema、RLS、ACL、依賴與回滾策略。
3. 不將 disposable current-state snapshot 當作歷史 migration baseline。兩者回答不同問題。
4. Replay harness、fixture、驗證 SQL 必須保留明確的 disposable-only 標示，且不可包含 Hosted Supabase credentials。
5. 標記為 Superseded 只代表不可再作為執行來源，不代表可立即刪除；先確認引用關係與保留證據。
6. 每次分類變更都要附上核對依據、日期、對應 PR／migration，以及是否已在 Hosted 套用。

## 本輪限制

本輪只對上述可直接讀取並核對內容的檔案分類。尚未完成 `supabase/drafts/` 全目錄清單與全引用圖，因此**不執行批次刪除、不搬移 SQL、不宣稱全目錄分類完成**。
