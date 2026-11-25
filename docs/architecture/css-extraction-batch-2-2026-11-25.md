# CSS 抽離批次 2：城市地圖與地點面板（2026-11-25）

## 範圍
- `city-map-ui.css`：原本城市地圖 style blocks 1–5（主舞台、玻璃效果、容器 fix、手機導航、桌機 Dock）。
- `city-location-panel.css`：原本 `poyozz-city-location-panel` style block。

## 保留方式
- CSS 原文完全一致；只在檔案前加註解，已逐字比對原始 `index.html` blocks，兩個檔案內容 match。
- `city-map-ui.css` 在原第一個 city map style block 的位置引入，原本後續相鄰 city-map inline blocks 移除。
- `city-location-panel.css` 在原 location panel style block 的位置引入。
- 不改 selectors、declarations、theme、顏色、media queries、breakpoints、JS 或 HTML layout。
- 兩個 CSS 檔都沒有 `url()` 資產引用。

## CI / Vercel static output
- 加入 static runtime allowlist：`city-map-ui.css`、`city-location-panel.css`。
- 新增個別檔案 budget 16 KB / 33 KB；全站 1.5 MB runtime budget 不變。
- Vercel static-output workflow 已涵蓋 `*.css` trigger。

## 驗收
- 原始 CSS 逐字比對通過（city map 13,972 bytes；location panel 31,024 bytes）。
- HTML 仍保留 3 個 inline style blocks（global theme + chat layout/keyboard）；CSS links 順序已確認。
- 尚待 PR CI：static output allowlist、CSS URL asset resolution、CI workflows。
- Preview only；不執行 Supabase、Edge Function 或 Production 部署。
