# `supabase/drafts/` 分類索引

本目錄不是可直接部署的 migration 目錄。**任何草案都不得因為檔名含有 SQL、看起來完整或曾在測試中執行，就直接套用到 Hosted Supabase。**

## 最新盤點

- [全目錄清單、初步分類與引用關係](../../docs/architecture/supabase-drafts-inventory-2026-11-25.md)
- 124 個 Draft 檔案（67 SQL、51 Markdown、6 JSON）。
- 48 個引用命中檔案，涵蓋 CI、disposable fixture、測試腳本、migration provenance 與架構文件。
- 沒有執行 SQL、沒有刪除或搬移 Draft，也沒有修改 Hosted Supabase。

## 安全規則

1. 不刪除任何 SQL 草案，除非已確認沒有 replay script、CI workflow、文件或其他草案引用它。
2. 不把 Draft SQL 搬入 `supabase/migrations/`；正式 migration 必須核對歷史版本、現有 schema、RLS、ACL、依賴與回滾策略。
3. 不將 disposable current-state snapshot 當作歷史 migration baseline。
4. Replay harness、fixture、驗證 SQL 僅限 disposable/local 使用，不可包含 Hosted credentials。
5. Superseded 只代表不可再作為執行來源，不代表可立即刪除；先確認引用關係與保留證據。
