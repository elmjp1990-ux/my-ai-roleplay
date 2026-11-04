# Round 40 — 新建聊天室入口與角色封存後端授權查核（2026-11-02）

## 查核結果

### 單人聊天室
- 傳統／故事單聊建立不是專用 RPC；前端直接 INSERT `chat_sessions`。
- 已存在且屬於目前玩家的 session 使用 UPDATE；程式註解明確保留角色下架後既有劇情的保存能力。
- 新聊天使用 INSERT。前端目前允許作者對從未公開的私密角色建立測試聊天室；這是作者測試特權，不代表其他玩家可建立。
- RLS INSERT restrictive policy 呼叫 `character_can_start_chat(character_id)`；函式允許作者本人或公開且 approved 的角色，並排除 `deleted_at` 非空。
- 另一 restrictive policy 也排除已刪除角色。UPDATE policy 以 session owner 為核心，具備將既有 session continuation 與新 INSERT 分開的基礎。
- 未來必須在 INSERT policy / helper 中排除作者主動刪除封存與帳號刪除封存角色；作者特權不能繞過封存。

### 群組聊天室
- 前端呼叫 `create_chat_group()`。
- EXECUTE 僅 authenticated / service_role；anon 無權。
- 函式以 `auth.uid()` 作為 owner，檢查帳號待刪除狀態；每個角色必須 public 且 `deleted_at IS NULL`，並以 FOR SHARE 讀取。
- 尚無 account-archived 狀態檢查；未來必須在 RPC 內部阻擋封存角色。

### 相遇 session
- Edge Function 先用玩家 JWT 呼叫 `auth.getUser()`、`account_is_active()`、`can_open_encounter_session()`，再以 service-role 呼叫建立 RPC，並傳入由 getUser 取得的 user.id。
- 建立 RPC EXECUTE 僅 postgres / service_role；anon/authenticated 無權。
- SECURITY DEFINER RPC 本身沒有驗證 `p_user_id` 與可信使用者身分的綁定。現有 Edge 入口先驗證 JWT，但 RPC 參數不能被視為自我驗證；需設計可信中介綁定。
- `can_open_encounter_session()` 目前檢查 public、未刪除、approved、rights_confirmed 與 NSFW 年齡，沒有封存狀態。

### 故事 session
- Edge Function 先用玩家 JWT 驗證使用者及帳號狀態，再用玩家 JWT 呼叫 `character_can_start_chat()`。
- 最後以 service-role 呼叫 `create_story_session_with_relationship()` 並傳入 user.id。
- 建立 RPC EXECUTE 僅 postgres / service_role；SECURITY DEFINER body 未自行驗證使用者參數。
- `character_can_start_chat()` 允許作者本人（包括 private 角色）或公開 approved 角色，只排除 deleted_at；沒有封存狀態判斷。

## 已確認規則對應
- 作者可對尚未公開的私密角色建立測試聊天室；這是作者特權。
- 作者刪除／封存角色後，所有已開始對話的玩家都可繼續各自既有聊天室，角色對外呈現離線／私密。
- 封存角色不得建立任何新單聊、群聊、相遇或故事 session；作者本人也不能用測試特權繞過封存。
- 從未公開且完全沒有任何聊天／相遇／故事使用紀錄的角色，才可考慮立即永久刪除。
- 新 session 建立與既有 session continuation 必須分開授權。

## 待續查
1. 檢查 chat-turn、群組送訊息、相遇 turn、故事 turn 是否只驗證 session owner/狀態，並允許封存角色的既有 session 續聊。
2. 完成公開列表、城市地圖、推薦、搜尋與作者角色管理查詢的完整盤點。
3. 可靠判斷「完全沒有歷史」必須涵蓋 soft-deleted sessions、群組成員、相遇與故事紀錄；不可只看 chat_messages 數量。
4. 設計 lifecycle 狀態，區分作者私密、作者刪除封存、帳號刪除封存、永久刪除。
5. 重設 encounter/story service-role RPC 的可信使用者綁定並加入 bypass regression tests。

## 安全界線
PR #200 維持 Draft / unmerged。本輪只有 source read 與 Supabase SELECT/catalog 查詢；沒有 hosted DDL/DML、Auth/Storage mutation、部署或 Cron。
