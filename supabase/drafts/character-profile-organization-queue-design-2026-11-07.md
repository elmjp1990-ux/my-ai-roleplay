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


## 整理內容範圍（補充規格，2026-11-07）

整理結果分成「角色理解摘要」與「結構化角色事實」，避免把不同用途的資料混成一段人格摘要。以下是模型整理的目標分類；實際來源只讀取資料庫／角色卡已存在且有值的欄位，不自行假設或新增欄位。

### A. 角色核心理解（主要整理）

1. **基本背景與身份**：角色介紹、種族／身份、背景經歷、世界觀定位。
2. **核心人格**：核心特質、價值觀、內在動機、主要矛盾。
3. **說話方式**：語氣、用詞、句型、口頭習慣、表達節奏。
4. **行為模式**：行為規則、決策傾向、主動性、面對壓力或衝突時的反應。
5. **喜好與厭惡**：喜歡／不喜歡的人事物、活動、環境及互動方式。
6. **關係與界線**：親密關係節奏、信任建立方式、明確界線、不可接受事項。
7. **作者補充設定／私密設定**：保留其作者設定屬性，不得把推測改寫成作者明確設定，也不得把私密內容輸出到玩家可讀資料。

### B. 外觀與辨識特徵（次要整理）

- 只整理角色卡中實際存在的外觀、穿著、髮型、體態或辨識特徵。
- 作為場景描寫與角色一致性輔助，不得凌駕角色核心人格及作者原文。
- 若角色卡沒有提供，不可自行補完；可標記為「未提供」。

### C. 生活狀態與時間資訊（獨立分類，不混入人格摘要）

- 整理角色日程、活動、地點、時段，以及明確設定的作息／時間背景（僅限來源資料確實存在的內容）。
- 日程表是會變動的結構化資料，應優先保留原始 schedule 欄位與時段，不可只依賴 AI 摘要；AI 整理結果僅作輔助索引。
- 故事模式可依角色卡／故事設定使用，不得擅自套用即時現在時間；相遇模式才依既有台灣時間與公開日程判斷角色當下出現狀態。
- 若來源沒有明確時間或日程，不得自行推測角色目前正在做什麼。

### D. 明確排除：即時執行設定

- `phone_settings`／手機通知揭露指示屬於每回合執行時讀取的設定，必須由對話流程即時載入；不納入長期角色摘要，也不因修改手機通知而觸發本整理佇列。
- 角色名稱、標籤、立繪名稱、圖片／影片、排版等展示或搜尋欄位仍不觸發整理。

## 整理結果的可信度與衝突規則

每項整理結果都必須能區分以下來源屬性：

- **作者明確設定**：可回指角色卡／私密設定原文；不得改寫成相反意思。
- **AI 歸納**：由多個作者設定歸納出的穩定模式，必須標記為推論，不得偽裝成作者逐字設定。
- **未提供／未知**：來源沒有資料時明確留空或標記未知，不可自行填補。
- **待釐清／來源衝突**：作者欄位彼此矛盾時保留衝突提示，不由模型擅自選一個版本；若有明確更新時間或欄位權威順序，依已定義規則採最新且權威的作者來源，否則標記待釐清。

優先順序：作者明確來源 > AI 歸納 > 未知。任何 AI 推論都不能覆蓋作者原文；新一次儲存若改變來源，最新來源版本優先，舊 worker 的輸出必須因 source hash 不符而丟棄。

## 建議的結構化輸出形狀（實作時再定 JSON Schema）

- `identity_background`
- `core_personality`
- `speech_style`
- `behavior_patterns`
- `likes_dislikes`
- `relationship_boundaries`
- `appearance_markers`
- `life_schedule_context`
- `author_private_context`（嚴格私密，僅可信後端可讀）
- `unknowns`
- `source_conflicts`
- 每個分類需附來源欄位／來源類型／source hash 或版本資訊，方便驗證、更新與除錯。

這份輸出形狀是設計建議，尚未定稿為資料庫 schema；正式實作前需依實際欄位盤點建立 JSON Schema 與資料可見性測試。
