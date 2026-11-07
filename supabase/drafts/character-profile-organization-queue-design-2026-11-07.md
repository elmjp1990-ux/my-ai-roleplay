# POYOZZ 角色卡 AI 衍生資料整理佇列設計（草案）

狀態：設計草案，尚未建立正式 migration、worker 或部署。

## 目的

角色卡儲存時先由程式比對前後欄位。只有真正影響角色理解與行為的來源欄位變更，才排入一次 AI 衍生資料整理工作。儲存流程本身不直接呼叫模型，也不因單一欄位變更而呼叫多次。

指定整理模型：`deepseek/deepseek-v4-flash-20260423`。

## 來源欄位與觸發邊界

目前 classifier 的 AI 來源欄位：
- `characters.intro`
- `characters.race`
- `characters.style`
- `character_private_info.private_info`
- `character_private_info.personality_profile` 中的 `coreTraits`、`values`、`speechStyle`、`behaviorRules`、`likes`、`dislikes`、`boundaries`、`relationshipPacing`

不觸發衍生資料重整：
- 角色名稱、標籤、立繪名稱、圖片／影片、排版等展示或搜尋資料。
- `phone_settings`：這是每回合即時使用的 AI 執行設定，不是角色摘要來源。
- 空白的新角色不因建立本身觸發整理。

角色原始欄位永遠是權威資料；AI 產生的衍生資料只作輔助提示，不得覆蓋原始角色卡或私密設定。

## 持久化設計

使用兩個獨立資料表，不重用 `ai_model_usage`：

1. `character_profile_organization_jobs`
   - 每個角色最多一筆有效工作，使用 `character_id` 唯一鍵合併連續儲存。
   - 欄位至少包含：`character_id`、`author_id`、`source_hash`、`status`、`attempt_count`、`available_at`、`lease_token`、`lease_generation`、`lease_expires_at`、`last_error_code`、時間戳。
   - 狀態：`pending`、`processing`、`completed`、`failed`。
   - 連續儲存時更新來源版本／hash，清除舊 lease，讓舊 worker 無法提交過期結果。

2. `character_profile_organization`
   - 獨立保存 AI 整理後的結構化 JSON、來源 hash、模型名稱與生成時間。
   - 不把摘要寫回 `characters`、`character_private_info` 或角色原始欄位。

兩表均啟用 RLS，撤銷 `PUBLIC`、`anon`、`authenticated` 的直接資料表權限，只允許受控的資料庫函式／service role 存取。任何可由 authenticated 呼叫的 enqueue RPC 都必須驗證 `auth.uid()` 與角色作者一致，並明確撤銷 PUBLIC／anon 執行權。

## 工作流程

1. 角色卡原始資料寫入並完成回讀驗證。
2. 若 classifier 的 `requiresDerivedRefresh === true`，以單次 owner-checked enqueue RPC 寫入／合併工作；不在瀏覽器呼叫 OpenRouter。
3. Worker 以原子 claim（`FOR UPDATE SKIP LOCKED`）取得工作，使用 lease token + generation 防止重複 worker 同時提交。
4. Worker 讀取最新的角色公開來源欄位、作者私密欄位及個性欄位，計算一致的 source hash，再呼叫 DeepSeek V4 Flash。
5. 模型輸出必須通過嚴格 JSON/schema 驗證；錯誤只記錄安全錯誤代碼，不記錄 prompt、私密設定、對話內容或 API key。
6. 寫入衍生資料前，在同一資料庫交易內重新驗證 job lease 與最新來源 hash。只要來源已變更或 lease 已失效，就丟棄舊輸出，不得覆蓋新版本，並確保最新版本仍可重新排隊。
7. 失敗採有上限的指數退避；超過上限後標記 failed，保留安全錯誤碼供維運查詢。

## 必要安全與一致性條件

- 不以 `ai_model_usage` 充當工作佇列；它仍是模型成本／請求紀錄。
- 不在用戶端持有 service role key。
- 不讓玩家讀取工作佇列、私密來源或衍生整理結果。
- 角色刪除時，工作與衍生資料需依角色生命週期一併清理或安全失效。
- 工作重試、重複 enqueue、worker timeout、lease 過期及生成期間再次儲存都必須具備冪等性。
- AI 失敗不得影響角色卡原始資料儲存，也不得扣除玩家銀幣／鑽石。

## 尚未執行的工作

- 尚未建立正式 Supabase migration。
- 尚未建立 enqueue／claim／complete／fail RPC。
- 尚未建立 DeepSeek worker 或排程。
- 尚未呼叫模型、寫入正式資料庫或部署 Edge Function。

正式 migration 檔案必須在 Repo Terminal 中以 `supabase migration new <name>` 建立；本草案不應直接套用到任何資料庫。
