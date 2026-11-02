# Round 42 — 相遇建立重試與帳號刪除級聯風險（2026-11-02）

## 本輪程式修正

檔案：`supabase/functions/encounter-session/index.ts`

問題：Edge Function 原先先執行 `can_open_encounter_session()`，再查詢同一個 sessionId 是否已經建立。若第一次建立成功，但回應遺失，之後角色已被作者轉私密／刪除封存，玩家以相同 sessionId 重試時會先被「目前不可新建」擋下，無法取得既有 session 的 idempotent recovery。

修正：
- 將「同一玩家、同一角色、同一 Encounter mode、未刪除 session」的既有 session 查詢及 lifecycle/location 一致性驗證，移到新建資格檢查之前。
- 只有查無既有 session 時，才呼叫 caller-JWT 下的 `can_open_encounter_session()`，並檢查角色 public/approved/rights/deleted 狀態。
- 不接受不同 user、不同 character、不同 mode、已刪除 session 或不同 location 的 session ID collision。
- 因此只允許原 session owner 對同一 session 做安全重試；不會授予任何新 session 權限。

Commit：`64fc089dbe2547328a8ab23db03e68d6a0f91377`

## 本輪後端查核發現

### 群組新建
- `create_chat_group()` 目前要求每個成員角色 `visibility='public'` 且 `deleted_at IS NULL`，並以 `FOR SHARE` 讀取角色。
- 此 RPC 目前尚未有獨立 archive/lifecycle 欄位；未來增加角色封存狀態時，必須在此 RPC 內加入明確拒絕條件。
- `append_chat_group_mock_turn()` 驗證 auth.uid、account active、群組 owner、群組未封存/刪除，並使用建立時的 character_snapshot；既有群組訊息續聊不依賴角色目前公開狀態。

### 帳號刪除級聯風險（重大）
Read-only 查詢目前外鍵：
- `characters.author_id -> profiles.id ON DELETE CASCADE`
- `profiles.id -> auth.users.id ON DELETE CASCADE`
- 所以直接刪除 Auth user 會經由 profiles 將作者角色一併刪除，違反「帳號刪除保留所有角色內容與圖片、角色轉私密封存、保留歷史作者資訊」的政策。
- 多個作者互動資料表亦直接 cascade；帳號刪除 worker 在重新設計 profiles/author attribution、相關 FK 與清理策略前不可啟用。
- 角色本身的 chat_sessions / encounter lifecycle / story relationship 等引用多為 ON DELETE SET NULL；這只能避免歷史列因角色硬刪除而連帶刪除，不能代替保存角色快照及作者歸屬的完整策略。
- 本輪僅查詢 catalog，沒有執行任何 DDL/DML、Auth 刪除或 Storage 操作。

## 驗證範圍
- 重新讀取 branch 檔案，確認 existing-session lookup 位於 `can_open_encounter_session()` 之前。
- 尚未執行 Deno type-check、Edge Function integration test 或 E2E。
- 沒有修改 hosted schema/RLS/RPC、Auth、Storage、部署或 Cron。
- PR #200 維持 Draft/unmerged。

## 下一步
1. 為 Encounter create retry 加 regression test：既有 owner 的相同 sessionId 在角色封存後可 idempotent return；不同 sessionId 仍拒絕。
2. 建立帳號刪除 FK/資料保留重構方案，先在 PR draft 提供 migration 設計與 rollback，不套用 hosted DB。
3. 為 `create_chat_group()`、`character_can_start_chat()`、`can_open_encounter_session()` 導入一致的 archived/deleted eligibility contract，並保留 private unpublished author test 的限定例外。
