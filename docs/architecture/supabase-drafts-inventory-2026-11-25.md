# Supabase Draft 全目錄盤點與引用關係

- 基準：`8032ddc7e61cf2516d7d2f92bccd1a70882a48a8`（main，2026-11-25）
- 檔案數：**124**（SQL 67、Markdown 51、JSON 6；另有 README）
- 總大小：約 3.78 MB。

## 安全結論

1. `supabase/drafts/` 是設計、稽核、證據與隔離測試材料，不是可部署 migration 目錄。
2. 本輪不刪除、不搬移、不執行任何 Draft SQL。涉及帳號／角色／聊天室刪除、RLS、權限、wallet、encounter 排程的檔案保留其測試與復原價值。
3. `current-state-*.json` 是特定測試環境快照，不是乾淨 migration baseline。
4. replay/test/seed/verify/setup/disposable/export 類只可在 disposable/local fixture 使用，不可用 Hosted credentials。
5. `character-turn-count-parent-delete-filter-proposal.sql` 已在內容中標示被 `chat-deletion-cumulative-turn-statistics-proposal.sql` 取代；保留歷史但不可再作執行來源。
6. `group-chat-core-schema.sql` 是早期 schema proposal；已有後續 migration，但未逐欄位／constraint 比對，暫列歷史候選。

## 引用關係

GitHub code search 搜尋 `supabase/drafts/` 命中 **48 個檔案**。可識別的依賴包括：

- `scripts/build-disposable-schema-fixture.mjs`：建立 disposable schema fixture。
- `scripts/test-build-disposable-schema-fixture.mjs`、`scripts/test-disposable-schema-catalog-snapshot.mjs`：fixture 與 snapshot 測試。
- `.github/workflows/supabase-local-migration-replay.yml`：local migration replay workflow。
- `scripts/test-chat-deletion-turn-stats-draft.mjs`、`test-character-history-aware-deletion-draft.mjs`、`test-account-deletion-character-preservation-draft.mjs`：刪除／turn statistics draft 測試。
- `scripts/test-chat-write-guard-concurrency.sh`：寫入保護併發測試。
- `scripts/test-character-ai-profile-contract.mjs`：AI Profile JSON schema／registry 契約。
- `scripts/test-encounter-schedule-worker.mjs`、`test-encounter-session-evaluation-worker.mjs`：排程與評估 worker 測試。
- account deletion、chat deletion、message write guard 等 GitHub Actions workflows：保留測試引用。
- `supabase/migrations/20261104200100_poyozz_account_deletion_preservation_atomic_lease.sql`：與 atomic lease draft 有 provenance 關聯，不可用 draft 覆寫 migration。
- 架構文件 `migration-source-audit`、`FEATURE-OWNERSHIP-MAP`、`codebase-refactor-batches`：保留決策依據。

命中不等於每個檔案都會被執行；有測試／workflow／文件依賴者先保留，逐檔核對後才考慮封存。

## Python 舊圖片工具判定

- `scripts/optimize-brand-assets.py` 全 repo 精確搜尋：**0 命中**。
- `.github/workflows/optimize-brand-assets.yml` 只執行 `scripts/optimize-brand-assets.mjs`。
- MJS 使用 Node + sharp，已涵蓋品牌圖與 encounter scene；`package.json` 無 Pillow/Python runtime dependency。
- 結論：Python 版沒有程式／文件／workflow 引用，功能已由 MJS 取代，可安全移除。

## 全目錄檔案清單（124）

| 檔案 | 初步分類 | 決定 |
|---|---|---|
| `account-archived-character-session-insert-guard.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-archive-access-control-audit-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-archive-prepare-character-data-loss-audit-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-author-profile-dependency-inventory-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-character-child-write-freeze-tests-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-character-child-write-freeze.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-character-preservation-and-profile-fk-redesign-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-character-preservation-draft.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-character-preservation-policy-review-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-character-preservation-schema-and-ui-audit-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-chat-history-and-group-charge-audit-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-conversation-and-financial-retention-audit-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-durable-creator-attribution-schema-design-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-never-published-character-policy-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-retention-policy-conflict-and-worker-kill-switch-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-storage-sweep-audit-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-worker-atomic-lease-design-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-worker-atomic-lease.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `account-deletion-worker-concurrency-audit-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `account-is-active-auth-user-existence-guard-tests-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `account-is-active-auth-user-existence-guard.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `character-ai-profile-source-registry-v1.json` | AI Profile schema／來源契約 | 保留；不可僅依檔名刪除或部署 |
| `character-ai-profile-v1.schema.json` | AI Profile schema／來源契約 | 保留；不可僅依檔名刪除或部署 |
| `character-creation-and-existing-chat-authorization-audit-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `character-deletion-existing-chat-continuation.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `character-deletion-existing-player-chat-access-requirements-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `character-history-aware-deletion.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `character-history-fk-classification-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `character-profile-organization-queue-design-2026-11-07.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `character-turn-count-migration-provenance-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `character-turn-count-parent-delete-filter-proposal.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `characters-baseline-provenance-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-archive-memory-photo-read-access.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-access-control-matrix-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-aggregate-count-and-trigger-audit-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-cumulative-turn-statistics-proposal.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-data-model-and-state-machine-2026-11-01.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-direct-parent-delete-privilege-guard.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-final-acceptance-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-frontend-cache-acceptance-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-lifecycle-reconciliation.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-migration-phase-a-snapshot-2026-11-01.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-purge-cron.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-retention-matrix-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-retry-and-migration-reconciliation-plan-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-sql-writer-path-inventory-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-turn-stats-structural-verification.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `chat-deletion-worker-runbook-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-message-write-guard-tests.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-migration-inventory-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-turn-assistant-update-guard.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `chat-turn-stale-reconciliation.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `chat-turn-validation-matrix.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `chat-turn-wallet-charging.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `current-state-effective-grants.json` | 唯讀快照／權限證據 | 保留；不可僅依檔名刪除或部署 |
| `current-state-routines.json` | 唯讀快照／權限證據 | 保留；不可僅依檔名刪除或部署 |
| `current-state-schema-catalog-manifest-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `current-state-security.json` | 唯讀快照／權限證據 | 保留；不可僅依檔名刪除或部署 |
| `current-state-structure.json` | 唯讀快照／權限證據 | 保留；不可僅依檔名刪除或部署 |
| `deletion-lifecycle-integration-plan-2026-11-01.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `disposable-platform-bootstrap.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `encounter-create-idempotency-and-account-delete-fk-audit-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `encounter-diary-chat-deletion-lifecycle-guard.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `encounter-evaluation-deletion-gate-proposal.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `encounter-evaluation-evidence-gates.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `encounter-existing-session-continuation-fix-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `encounter-lifecycle-trigger-attachment-audit.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `encounter-relationship-greeting-pools.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `encounter-schedule-pipeline.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `encounter-session-delete-lifecycle-guards.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `encounter-session-manual-end.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `export-disposable-schema-catalog.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `group-chat-core-schema.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `legacy-image-migration-rpcs.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `live-nsfw-turn-count-gate-provenance-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `local-replay-baseline-provenance-gap-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `migration-ledger-repository-manifest-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `migration-source-recovery-from-ledger-2026-11-03.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `migration-version-collision-replay-hazard-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `pr200-final-privilege-hardening.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `pr200-migration-security-review-2026-11-03.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `pr200-runtime-and-migration-status-2026-11-03.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `prepare-account-deletion-character-preservation-integration.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `public-truncate-privilege-audit-2026-11-01.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `replay-account-deletion-release-migration.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-and-test-character-deletion.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-deletion-concurrency-setup.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-per-turn-affinity.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-relationship-greeting-pools.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-scene-catalog.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-schedule-batch-semantics.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-schedule-output-repair.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-schedule-output-soft-hide.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-schedule-pipeline.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-schedule-repair-drafts.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-session-evaluation-worker.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-sparse-schedule-windows.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-worldview-manual-review.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-encounter-worldview-review-decisions.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-local-security-drafts.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `replay-schedule-encounter-evaluation-worker.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `retained-character-ownership-and-archived-chat-access-audit-2026-11-02.md` | 稽核／證據／驗收文件 | 保留；不可僅依檔名刪除或部署 |
| `revoke-public-truncate-privileges-proposal.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `schedule-encounter-evaluation-worker.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `seed-character-deletion-legacy-fixtures.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `seed-legacy-image-migration-local-test.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `settle-encounter-session-parent-lock-live-reconciliation.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `setup-chat-write-guard-concurrency.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `sync-character-chat-snapshot-parent-lock-proposal.sql` | SQL 提案／guard／歷史實作候選（須核對 migration 與引用） | 保留；不可僅依檔名刪除或部署 |
| `synthetic-disposable-baseline-design-2026-11-02.md` | 設計／規格／流程文件 | 保留；不可僅依檔名刪除或部署 |
| `test-account-deletion-character-child-rls-freeze.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `test-account-deletion-character-preservation-behavior.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `test-account-deletion-character-schedule-write-freeze.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `test-account-deletion-character-storage-write-freeze.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `test-account-deletion-worker-lease-security.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `test-account-photo-storage-e2e-fixture.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `test-character-deletion-behavior.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `test-chat-archive-memory-photo-read-access.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `test-chat-message-write-guards.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `test-only-premise-and-migration-ledger-reconciliation-2026-11-02.md` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `verify-current-state-schema-fixture.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `verify-deletion-draft-replay.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `verify-deletion-draft-rollback.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |
| `verify-legacy-image-migration-local-test.sql` | 隔離測試／replay／fixture（不可部署 Hosted） | 保留；不可僅依檔名刪除或部署 |

## 全部 code-search 命中檔案（48）

- `supabase/drafts/README.md`
- `supabase/drafts/chat-deletion-lifecycle-reconciliation.md`
- `supabase/drafts/synthetic-disposable-baseline-design-2026-11-02.md`
- `docs/architecture/migration-source-audit-2026-11-15.md`
- `supabase/drafts/replay-local-security-drafts.sql`
- `docs/architecture/FEATURE-OWNERSHIP-MAP.md`
- `scripts/build-disposable-schema-fixture.mjs`
- `supabase/drafts/replay-account-deletion-release-migration.sql`
- `supabase/drafts/replay-deletion-concurrency-setup.sql`
- `supabase/drafts/chat-turn-validation-matrix.md`
- `supabase/drafts/pr200-migration-security-review-2026-11-03.md`
- `supabase/drafts/current-state-schema-catalog-manifest-2026-11-02.md`
- `supabase/drafts/chat-deletion-sql-writer-path-inventory-2026-11-02.md`
- `supabase/drafts/live-nsfw-turn-count-gate-provenance-2026-11-01.md`
- `supabase/drafts/character-turn-count-migration-provenance-2026-11-01.md`
- `supabase/drafts/characters-baseline-provenance-2026-11-02.md`
- `supabase/drafts/pr200-runtime-and-migration-status-2026-11-03.md`
- `supabase/drafts/encounter-session-delete-lifecycle-guards.sql`
- `supabase/drafts/account-deletion-character-preservation-policy-review-2026-11-02.md`
- `supabase/drafts/account-deletion-worker-concurrency-audit-2026-11-02.md`
- `supabase/drafts/migration-version-collision-replay-hazard-2026-11-01.md`
- `supabase/drafts/character-profile-organization-queue-design-2026-11-07.md`
- `supabase/drafts/account-deletion-worker-atomic-lease-design-2026-11-02.md`
- `supabase/drafts/account-deletion-character-preservation-draft.sql`
- `supabase/drafts/character-turn-count-parent-delete-filter-proposal.sql`
- `docs/architecture/codebase-refactor-batches-2026-11-15.md`
- `supabase/migrations/20261104200100_poyozz_account_deletion_preservation_atomic_lease.sql`
- `scripts/test-build-disposable-schema-fixture.mjs`
- `scripts/test-disposable-schema-catalog-snapshot.mjs`
- `supabase/drafts/replay-and-test-character-deletion.sql`
- `supabase/drafts/chat-message-write-guard-tests.md`
- `scripts/test-chat-deletion-turn-stats-draft.mjs`
- `scripts/test-character-history-aware-deletion-draft.mjs`
- `scripts/test-encounter-schedule-worker.mjs`
- `scripts/test-chat-write-guard-concurrency.sh`
- `scripts/test-encounter-ai-output.mjs`
- `scripts/test-encounter-session-evaluation-worker.mjs`
- `scripts/test-account-deletion-character-preservation-draft.mjs`
- `scripts/test-character-ai-profile-contract.mjs`
- `scripts/test-encounter-chat-mode-guard.mjs`
- `.github/workflows/encounter-ai-turn.yml`
- `.github/workflows/group-background-syntax.yml`
- `.github/workflows/chat-storage-api-retry-e2e.yml`
- `.github/workflows/supabase-local-migration-replay.yml`
- `.github/workflows/chat-deletion-worker-tests.yml`
- `.github/workflows/account-deletion-worker-tests.yml`
- `.github/workflows/chat-message-write-guard-tests.yml`
- `.github/workflows/story-ai-content-refusal-tests.yml`

## 後續核對

- 非 replay/test SQL：逐項比對 migrations、migration ledger、table／column／function／trigger／policy／grant，確認是否完整被取代。
- replay/test SQL：核對 workflow／script 的實際讀取路徑與執行順序。
- 大型 JSON snapshots：確認是否仍被測試讀取；未確認前保留。
- 清理候選另開 PR，逐檔附 evidence；不批次刪除。
