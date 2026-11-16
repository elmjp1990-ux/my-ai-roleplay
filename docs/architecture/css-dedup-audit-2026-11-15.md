# CSS 去重盤點 — 2026-11-15

## 檢查範圍

- `poyozz-ui.css`
- `index.html` 內 13 個 inline `<style>` 區塊
- 比對時保留 `@media`、`@supports`、`@container` 等條件上下文，不把不同 viewport／裝置狀態視為同一條規則。

## 結果

- 共掃描 1,059 個一般 CSS rule blocks。
- 在相同條件上下文中，沒有找到 selector 與完整 declaration block 都完全相同、可直接安全刪除的重複規則。
- 有不少 selector 重複出現，但 declaration 不同，屬於 cascade、主題覆寫、地圖不同階段樣式或手機／桌面條件式樣式。
- 例如 `.entry-menu` 的 `opacity:1` 分別位於 `@media (hover:none)` 與窄螢幕條件；兩者不能合併成全域規則，否則可能改變桌面 hover 行為。
- `:root`、`body.day`、`.card`、`.hero`、城市地圖卡片與按鈕等重複 selector 具有不同宣告或條件，不視為可刪除的重複程式碼。

## 本輪處理決定

**不直接刪除任何 CSS 規則。** 目前沒有證據支持安全刪除；以文字相似或 selector 重複為理由刪除，可能破壞主題、地圖及手機版樣式。

下一輪若要繼續瘦身，應按元件／頁面抽取樣式，並先確認最後生效的 cascade，再以桌面、手機、白天／黑夜及地圖／聊天室模式做視覺回歸。不要用單純 selector 去重工具自動改寫。
