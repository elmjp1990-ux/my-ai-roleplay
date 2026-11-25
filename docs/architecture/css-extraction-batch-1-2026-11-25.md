# CSS 抽離批次 1（2026-11-25）

從 `index.html` 原第 7–11 個 inline style block 抽出五個功能 CSS 檔，並在原本位置換成 stylesheet link，維持 cascade 順序：

- `memory-album.css`：回憶相簿
- `wallet-ui.css`：錢包費用與資源顯示
- `group-author-forms.css`：作者追蹤、群組成員／表單
- `character-illustration-gallery.css`：角色立繪圖庫
- `chat-composer-states.css`：聊天輸入列狀態、送出中狀態

本批只搬移 CSS 原文，不改 selector、declaration、media query、色彩、變數或斷點。link 取代 style 的位置與原 style block 一致；原本的 `body.day` theme variables 與手機 media queries 均保留。

Vercel static allowlist、單檔 bytes budget、外部 CSS url() 引用檢查及 workflow CSS trigger 一併更新。

**驗收限制：** 靜態輸出與資源引用可由 CI 驗證，但尚未在真實瀏覽器完成桌機／手機 × 日間／夜間四象限截圖比較。此 PR 不應在 Preview 視覺驗收前合併。需檢查地圖、聊天室、相簿、錢包、群組建立及角色立繪畫面。
