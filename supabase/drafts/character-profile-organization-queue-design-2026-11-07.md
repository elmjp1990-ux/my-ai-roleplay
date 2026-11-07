# POYOZZ 角色卡 AI 衍生資料整理佇列設計（草案）

狀態：PR #215 分支已建立 migration、enqueue／claim／complete／fail RPC、DeepSeek Worker、Story prompt 讀取與測試；尚未套用 hosted migration 或部署。

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


## Character AI Profile 與正式對話輸出規範（整合定稿方向，2026-11-07）

本節將角色卡 AI 衍生資料（Character AI Profile）與正式網站每回合共用的輸出規範整合。兩者用途不同：Profile 描述「這個角色是誰、如何思考與行動」；共用輸出規範約束「所有角色的每次回覆如何演出與呈現」。不得只在盲測程式中套用，正式網站角色對話流程也必須載入。

### 一、Character AI Profile：角色扮演檔

一次角色資料整理工作應以指定模型 `deepseek/deepseek-v4-flash-20260423` 整理以下分類；不為每個分類分別呼叫模型。作者原始資料始終是權威來源，衍生資料只能輔助角色理解。

1. **身份與背景**：身份、背景經歷、世界觀定位；只整理作者確實提供的資訊。
2. **核心人格與價值觀**：穩定性格、重視的事物、信念、內在矛盾及價值取捨。
3. **內在動機與目標**：角色想追求、想守護、害怕失去及尚未完成的目標；來源不足時標記未知，不捏造。
4. **情緒反應模式**：面對開心、害羞、生氣、嫉妒、受傷、壓力及衝突時可能呈現的反應傾向；描述選擇範圍，不寫成每次必須觸發的固定腳本。
5. **關係發展邏輯**：信任、好感、親密、衝突與和解的合理節奏及界線；不得無過程地改變關係。
6. **行為模式與自主性**：決策傾向、主動性、生活目標、分享生活、發起活動、拒絕或表達不同意見的方式。角色不應只等待玩家提問，也不必一味迎合玩家。
7. **知識範圍與記憶邊界**：角色已知、未知及可合理觀察的資訊；AI 知道不代表角色知道。
8. **說話風格**：僅整理有來源支持的表達傾向，例如整體語氣、表達節奏、正式／私下場合差異、幽默或吐槽傾向。不得把傾向轉成每句必須執行的模板。
9. **外觀辨識特徵**：僅整理作者提供的外觀、穿著、髮型、體態及辨識資訊；不可自行補完。
10. **生活與時間背景**：作者明確提供的日程、作息、活動、地點及時段；原始 schedule 結構仍為權威來源，故事模式不得擅自套用即時現在時間。
11. **作者私密補充**：保留私密屬性，只供授權後端使用，不得輸出至玩家可讀資料。
12. **未知與來源衝突**：明確列出未提供、未知及互相矛盾的來源，不得自行裁決或捏造。

### 二、OOC 防止人設崩塌規則

- 每個角色至少整理 **3 條 OOC 規則**，根據作者實際提供的人格、背景、行為、關係及界線設定產生。
- OOC 是角色內部扮演約束，不是玩家可見台詞，也不是固定劇情。
- 每條規則應具體說明需維持的角色特徵、不可發生的不合理偏移，以及允許的自然發展空間。
- OOC 不可與作者原始設定矛盾，不可憑空新增作者未提供的創傷、秘密、能力或關係史。
- OOC 防止無理由的人設突變，但不能把角色鎖死。例如慢熟角色可以隨互動逐漸親近，但不能毫無鋪墊地突然完全信任玩家。
- 資料不足時仍需至少整理可由現有資料支持的規則；若不足以形成三條實質規則，應標示資料不足並避免虛構內容，交由後續補充，而非湊數捏造。

### 三、說話習慣與語言特徵的限制

這一分類採「分析表達傾向，不製造口頭禪」原則：

- **口頭禪／固定慣用詞**：只有作者明確指定時才納入；作者未提供時不自動生成。
- **範例句／示範台詞**：不主動提供，以免模型把範例當成高頻模板而反覆照抄。
- **句子長短、語氣、表達節奏**：可以歸納為寬鬆傾向，不得變成每句固定格式。
- **玩家稱呼**：只有作者明確設定時才固定使用；否則依關係與情境自然稱呼。
- **幽默、反問、吐槽、轉移話題、正式與私下差異**：只在來源有依據時整理成非強制傾向，不要求每次使用。
- 禁止為了表現個性刻意重複相同詞彙、句型、語助詞或台詞；不得把語言分析當成每回合必須執行的 checklist。
- AI 可以理解角色「通常如何表達」，但不得指定角色「每次必須怎麼說」。自然度與當下情境優先。

### 四、正式網站共用輸出規範（每回合強制套用）

以下規範屬平台共用生成指令，必須由正式網站後端在每次角色對話模型呼叫時載入；不能只放在盲測程式，也不能只依賴前端排版修正。角色 Profile 與作者 OOC 不得取消或覆蓋這些共用格式要求。

1. **臨場感**：依當下劇情自然呈現場景、氛圍、動作、姿勢、情緒、心理、對白、感官細節及符合情境的身體反應／部位。不是每次機械式塞入全部項目；不得為了清單完整而灌水。
2. **段落交錯**：動作／敘事與台詞自然交錯推進；互動場景須清楚呈現身體互動、攻防、距離變化與情感流動，不可只有對白或連續堆疊動作。
3. **禁止灌水與循環**：禁止重複敘述、同義改寫灌水、段落循環及劇情原地踏步。每段應帶來新的資訊、行動、反應或情緒變化；不得為達字數而添加無意義內容。
4. **代詞主體明確**：清楚區分 `{CHAR}`、`{USER}` 及其他角色；代詞省略須符合語境。多角色場景避免指涉混亂，明確交代動作執行者與承受者，不得擅自把玩家行為、想法或感受改寫成角色自身的。
5. **玩家內心資訊隔離**：除非角色依作者設定具備相應特殊能力，否則不得得知玩家以內心話形式描寫的內容。玩家內心話僅供 AI 內部理解上下文及安排後續演繹；角色只能依其可觀察到的言語、動作、表情及環境資訊反應，不得直接回應未表達的想法。
6. **禁止結尾引導玩家行動**：任何劇情、對話或場景描述的結尾，禁止使用「你該如何回應？」「接下來你會怎麼做？」「你的選擇是？」或任何變相要求玩家回答、選擇、採取指定行動的提示。角色可以在自然對話中提出符合情境的問題，但不得以旁白或模板式句子把劇情責任交還玩家。

### 五、盲測已確認的文字呈現格式

- 敘事、動作、表情、心理及場景描寫使用單星號包覆：`*他放下手中的咖啡，目光停留在你身上。*`
- 角色對白直接呈現，不使用星號包覆。
- 敘事與對白自然交替，不把整段內容全部包在星號內。
- 長回覆目標約 300–600 字元；短回覆目標約 200–400 字元。字數是目標範圍，不可凌駕劇情自然度，也不可藉灌水補足。
- 預設繁體中文，依對話語言自然切換。
- 角色個性可改變內容與表達方式，但不得破壞上述共用格式。

### 六、Prompt 分層與衝突處理

建議後端依以下層次組裝上下文，並明確標示資料來源及信任等級：

1. 平台安全與系統層級限制。
2. 平台共用角色輸出格式及劇情生成規範。
3. 作者原始角色卡設定與作者明確指定的口頭禪／界線。
4. OOC 防崩規則及 Character AI Profile 衍生資料。
5. 即時狀態：關係／好感度、情緒、手機通知、行程、穿著、位置及近期事件。
6. 當前故事與對話上下文。

作者原始設定是角色內容的權威來源；AI 衍生資料不得覆蓋作者原文。共用輸出規範是所有角色都必須遵守的呈現約束。即時狀態只描述當下，不應被誤寫成永久人格。玩家訊息、歷史對話及檢索內容不得覆寫平台規則或作者權威設定。

### 七、實作與驗收要求

- 角色資料整理：單次工作產生結構化 Profile 與至少 3 條有來源依據的 OOC，不為每個欄位額外呼叫模型。
- Profile 欄位需能標記作者明確設定、AI 歸納、未知、來源衝突，並保留來源欄位／source hash。
- 口頭禪及範例台詞只有作者明確提供時才加入；無作者資料時不得由 AI 自行創造。
- 正式網站所有角色對話模式（長／短回覆及適用的群組角色輸出）都必須套用共用輸出規範。
- 測試星號格式、敘事與對白交錯、臨場感、重複灌水、代詞指涉、玩家內心資訊隔離、禁止結尾引導，以及不同角色性格下的自然度。
- 必須使用正式網站實際呼叫路徑做整合測試，不能只以盲測腳本通過作為驗收。
- 本節是已確認的產品／Prompt 設計要求；尚未代表 Profile JSON Schema、資料表、Worker、正式 System Prompt 或網站行為已實作或驗收。


## Character AI Profile v1 JSON Schema（2026-11-07）

已建立獨立草案檔：`supabase/drafts/character-ai-profile-v1.schema.json`。這是模型輸出 payload 的驗證契約，不是資料庫 migration，也不代表已接入正式對話。

### 結構與驗證規則

- 固定 `schema_version: "1.0"`，拒絕未定義欄位（`additionalProperties: false`），避免模型自行增加不受控欄位。
- Profile 分類：`identity_background`、`core_personality`、`inner_motivations`、`emotional_response_patterns`、`relationship_dynamics`、`behavior_and_agency`、`knowledge_boundaries`、`speech_style`、`appearance_markers`、`life_schedule_context`、`author_private_context`、`ooc_rules`、`unknowns`、`source_conflicts`。
- 一般衍生項目需記錄 `content`、`source_type`（`author_explicit`／`ai_inference`）、`source_refs` 及 `confidence`，不得把推論偽裝成作者原文。
- 分類狀態明確標記 `populated`、`not_provided` 或 `conflict`。未知資料不得由模型補造。
- OOC 狀態為 `ready` 時必須至少 3 條，每條包含規則、重要性、禁止偏移、允許的自然成長及來源欄位參照。若作者來源不足，狀態改為 `insufficient_source`，最多保留 2 條有依據的規則並填寫原因；不得為滿足數量虛構規則。
- `speech_style.creator_defined_quirks` 只接受作者明確提供的口頭禪；`example_lines` 強制為空陣列，避免模型模仿固定示範句。
- `author_private_context.visibility` 固定為 `server_only`。資料庫、API、日誌及前端都必須維持私密隔離；只有經授權的後端角色對話 prompt 組裝流程可讀取必要內容。
- `source_conflicts` 必須保留衝突來源參照，狀態為 `needs_author_clarification`，不得自行選邊。

### 來源參照格式與實作注意

`source_refs` 應使用穩定欄位路徑，例如 `characters.intro`、`characters.race`、`characters.style`、`character_private_info.private_info`、`character_private_info.personality_profile.coreTraits` 等；不可放入整段私密原文、prompt 或使用者對話。

Schema 只驗證資料形狀，不能單獨證明 source_refs 真實存在或使用者有權讀取。Worker 還必須以程式 allowlist 驗證來源路徑、作者身份、source hash、欄位私密等級；模型不得自行發明 source_refs。模型輸出需在 server-side 驗證、正規化後才能寫入。

### 後續實作順序

1. 以實際資料庫欄位與 classifier allowlist 核對所有來源路徑，形成固定 source registry。
2. 加入 JSON Schema validator 與 source_refs allowlist 測試。
3. 明確定義資料庫儲存及對話 prompt 的 private/public 投影；私密作者補充不得進入玩家可見回應、一般 API 或日誌。
4. 再設計 migration、owner-checked enqueue、worker、lease 與 stale-source 防護。
5. 最後接入正式 Story 對話 prompt，並以網站實際路徑驗收。

本 schema 目前為設計草案；尚未有程式驗證器、資料表、佇列或模型呼叫接入。


## Source registry 對照與即時資料邊界（2026-11-07）

已根據 PR #215 分支目前角色儲存 classifier 與正式 `chat-turn` 讀取方式，建立 `supabase/drafts/character-ai-profile-source-registry-v1.json`。這份 registry 是 worker 可讀來源的 allowlist 草案。

### 目前確認會觸發 Profile 重整的欄位

- `characters.intro`
- `characters.race`
- `characters.style`
- `character_private_info.private_info`
- `character_private_info.personality_profile.coreTraits`
- `character_private_info.personality_profile.values`
- `character_private_info.personality_profile.speechStyle`
- `character_private_info.personality_profile.behaviorRules`
- `character_private_info.personality_profile.likes`
- `character_private_info.personality_profile.dislikes`
- `character_private_info.personality_profile.boundaries`
- `character_private_info.personality_profile.relationshipPacing`

其中 `character_private_info.*` 是作者私密來源，只能由授權後端讀取；模型輸出的 source_refs 只能引用本次工作實際提供且通過 allowlist 的欄位。

### 不觸發長期 Profile 重整的即時／展示資料

- `characters.name`、`gender`、`age`：作為當回合角色識別／背景欄位直接提供，不因改名或這些即時欄位變動而重建衍生 Profile。
- `characters.phone_settings`：每回合由對話流程即時讀取。
- `character_schedules`、`character_schedule_descriptions`：保留原始結構與作者文字為權威來源，依相遇／故事模式需要即時載入；不複製成長期 Profile，避免排程更新後摘要過期。
- tags、圖片／影片、立繪 metadata、`personality_profile.primaryIllustrationName`：展示或搜尋用途，不觸發重整。

### Schema 修正

`character-ai-profile-v1.schema.json` 已移除 `life_schedule_context`。行程與手機都是 runtime context，不是長期人格衍生資料；正式對話組裝時應獨立讀取最新資料。Profile 保留 `appearance_markers`，但只能根據本次工作提供的作者來源歸納，不得推測補完。

### 已核對的程式現況與限制

- PR #215 的角色儲存 classifier 目前只產生差異決策，`shouldCallModel: false)，尚未 enqueue 或呼叫整理模型。
- Story `chat-turn` 已讀取 `characters` 的角色背景／外觀欄位及 `character_private_info.private_info, personality_profile`，並組裝既有 prompt context。
- 目前 `prompt-context.ts` 只格式化既有 personality_profile 的六個主要欄位，尚未載入新的 Character AI Profile 或 OOC。
- 因此本次建立的 schema 與 registry 是下一階段實作契約；沒有修改正式對話 prompt、資料庫或 Edge Function。

### 實作時必須補上的防護

- 將 classifier 的 changedFields 與 registry 對照，避免兩份 allowlist 漂移。
- worker 讀取來源時以欄位 allowlist、角色 author_id、私密資料權限共同驗證。
- source hash 必須涵蓋本次全部 AI 來源欄位的正規化值；runtime-only 欄位不納入。
- schedule／phone 每回合按需即時讀取，絕不可使用 Profile 內舊副本。


## 最新實作狀態覆蓋更新（2026-11-07）

本草案前段「尚未接入正式 Prompt」為建立當時的狀態；截至 PR #215 分支 commit `8aab78994a682f5542af3ceb2bc3424c03774e`，Story `chat-turn` 共用 system prompt 已加入並通過 CI 的共用輸出規範，包括星號敘事／對白區分、敘事動作與台詞自然交錯、臨場感／感官／身體互動、禁止重複灌水與段落循環、代詞主體、玩家內心資訊隔離，以及禁止以引導玩家行動的問題句收尾。

測試 `scripts/test-story-roleplay-prompt.mjs` 已增加回歸斷言；`scripts/test-character-ai-profile-contract.mjs` 驗證 schema／source registry／classifier 的靜態契約。對應 Story AI workflow 中 Prompt 測試、Profile 契約測試與 `deno check supabase/functions/chat-turn/index.ts` 均通過。

仍未完成：
- Character AI Profile 與 OOC 尚未載入正式 chat-turn prompt。
- 尚無正式 JSON Schema runtime validator。
- 尚無 profile queue table、enqueue／claim／complete RPC、worker 或 DeepSeek 整理呼叫。
- 尚未追到並接通短回覆模式的前端參數；目前 `chat-turn` 呼叫端只傳 turn/session/message IDs，沒有 reply-length mode，正式 prompt 目前以 300–600 字元長回覆為目標。
- 未部署 Edge Function，未執行 hosted Supabase migration，未改動正式資料庫。

上述狀態只描述 PR 分支程式與 CI，不代表正式網站已生效；需等 PR 合併及授權部署後才會上線。


## PR #215 實作進度（2026-11-07）

已在 PR #215 分支新增：

- `supabase/migrations/20261107120000_character_ai_profile_organization_queue.sql`：建立私有 job queue 與 derived profile 表；owner-checked enqueue；service-role claim／complete／fail；SHA-256 source hash；lease token + generation fencing；過期來源結果拒絕寫入；Story 讀取 RPC 只回傳與最新來源 hash 相符的 Profile。
- `supabase/migrations/20261107123000_schedule_character_profile_organization_worker.sql`：可選 pg_cron + pg_net 排程。只在 Vault 內同時存在 `poyozz_supabase_url`、`poyozz_service_role_key` 且 scheduler extensions 可用時建立每分鐘排程；缺少條件會 fail closed，不會建立排程。加入 Vault secrets 後可由 service_role 呼叫 `schedule_character_profile_organization_worker()` 安裝／重建排程。
- `supabase/functions/character-profile-organization-worker/index.ts`：以 `deepseek/deepseek-v4-flash-20260423` 單次整理整份角色 Profile，採單筆 claim，失敗指數退避最多 5 次。
- `supabase/functions/_shared/character-profile-organization.ts`：模型輸出嚴格驗證、來源欄位參照 allowlist、作者私密來源限制、OOC ready 至少 3 條、禁止 AI 生成範例台詞。
- `index.html`：角色原始資料寫入並回讀驗證後，僅 AI 相關欄位變更才呼叫 owner-checked enqueue；enqueue 失敗不回滾角色資料，並回報保存警告。
- `supabase/functions/chat-turn/index.ts`：每回合透過 service-role RPC 讀取 source-hash 有效 Profile，將角色理解與 OOC 注入 Story system prompt；私密來源衍生項目加入既有輸出洩漏保護。
- 新增 Deno Profile validator tests、PostgreSQL migration/lease/stale-source tests，並加入 Story AI GitHub Actions。

排程部署前置條件：

1. Supabase Edge Function 設定 `OPENROUTER_API_KEY`。
2. Supabase Vault 建立 `poyozz_supabase_url`（專案 HTTPS URL）與 `poyozz_service_role_key`（service role JWT）。
3. 套用 migration 後確認 pg_cron、pg_net 與 Vault 可用；若 migration 當時尚無 Vault secrets，新增後由 service_role 呼叫排程 RPC。
4. Worker 每分鐘最多處理一筆，並以資料庫全域 active lease 避免同時生成多個角色，控制成本。

目前 GitHub Actions 的 Story AI tests、Worker Deno type-check、Profile/OOC tests 已通過；最新 SQL migration replay 正在執行。此狀態只代表 PR 分支與 CI，不代表 hosted Supabase 已套用或 Edge Function 已部署。

- Additional hardening: claim RPC now takes a transaction-scoped advisory lock before checking active leases, preventing simultaneous cron invocations from claiming multiple characters; processing is globally serialized to one active generation. A character soft-delete trigger immediately removes its pending job and backend-only derived Profile; hard deletes remain covered by FK cascades. PostgreSQL regression tests cover the competing-claim and soft-delete cases.
- The Profile validator now rejects unexpected properties at the root and each nested schema object, in addition to checking evidence references and OOC constraints.

- Cost visibility: added a separate service-role-only `character_profile_organization_usage` ledger for model, provider, request ID, prompt/completion/total tokens, provider cost, and safe status/error code. It stores no source text or prompts and is not used as a queue. Worker usage writes are non-blocking so a ledger outage cannot strand a valid Profile job.
- Profile requests follow the same approved OpenRouter policy as Story generation: `deepinfra` only, no provider fallback, and `data_collection: "deny"`; no `max_tokens` cap is added.
