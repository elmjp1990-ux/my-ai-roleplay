import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const html = readFileSync("index.html", "utf8");
const promptContext = readFileSync("supabase/functions/_shared/prompt-context.ts", "utf8");
const chatTurn = readFileSync("supabase/functions/chat-turn/index.ts", "utf8");

// Memory must be persisted with the session metadata and hydrated on cloud reload.
assert.match(html, /memories:\s*Array\.isArray\(s\.memories\)\s*\?\s*s\.memories\s*:\s*\[\]/);
assert.match(html, /memories:\s*Array\.isArray\(data\.memories\)\s*\?\s*data\.memories\s*:\s*\[\]/);

// Prompt context must prefer session memories, keep important/recent memories first,
// and provide the current player message separately from older chat history.
assert.match(promptContext, /session\.memories\s*\?\?\s*session\.memory/);
assert.match(promptContext, /Number\(b\.important\)\s*-\s*Number\(a\.important\)\s*\|\|\s*b\.at\s*-\s*a\.at/);
assert.match(promptContext, /USER_MESSAGE:\s*str\(current\?\.content\)/);

// The roleplay system instruction explicitly says a current player correction
// overrides conflicting stale memory.
assert.match(chatTurn, /新訊息若與舊記憶衝突，先以玩家當下明確更正為準/);

// Pin/unpin must persist and roll back local state if cloud sync fails.
const pinHandlerStart = html.indexOf("if (target.dataset.memory) {");
const pinHandlerEnd = html.indexOf("if (['aiImages','aiImageCount'].includes(target.id))", pinHandlerStart);
assert.ok(pinHandlerStart >= 0 && pinHandlerEnd > pinHandlerStart);
const pinHandler = html.slice(pinHandlerStart, pinHandlerEnd);
assert.match(pinHandler, /m\.important\s*=\s*target\.checked/);
assert.match(pinHandler, /await saveChatSessionSafely\(session\)/);
assert.match(pinHandler, /m\.important\s*=\s*previousImportant/);

// Important memories are read-only; ordinary memory edits/deletes are persisted
// and rolled back locally if cloud sync cannot confirm the write.
const memoryEditorStart = html.indexOf("case 'memory':");
const memoryEditorEnd = html.indexOf("case 'message-edit':", memoryEditorStart);
assert.ok(memoryEditorStart >= 0 && memoryEditorEnd > memoryEditorStart);
const memoryEditor = html.slice(memoryEditorStart, memoryEditorEnd);
assert.match(memoryEditor, /if \(!m \|\| m\.important\) return/);
assert.match(memoryEditor, /s\.memories\s*=\s*s\.memories\.filter/);
assert.match(memoryEditor, /await saveChatSessionSafely\(s\)/);
assert.match(memoryEditor, /s\.memories\s*=\s*memoryMutationTracker\?\.rollback\(s\.id,mutationVersion\)\s*\|\|\s*previousMemories/);

// Cloud writes and pending-turn metadata updates share one per-owner/session queue
// and capture immutable snapshots so out-of-order requests cannot overwrite newer state.
const saveStart = html.indexOf("async function saveChatSessionSafely(s) {");
const saveEnd = html.indexOf("async function refreshWalletBalance", saveStart);
assert.ok(saveStart >= 0 && saveEnd > saveStart);
const saveWrapper = html.slice(saveStart, saveEnd);
assert.match(saveWrapper, /const snapshot = s \? clone\(s\) : s/);
assert.match(saveWrapper, /chatSessionSaveQueue\(key, performSave\)/);
assert.match(saveWrapper, /memoryMutationTracker\?\.markSaved\(s\.id, snapshot\.memories\)/);

const clearStart = html.indexOf("async function clearCloudPendingTurn(s) {");
const clearEnd = html.indexOf("async function runPendingChatTurn", clearStart);
assert.ok(clearStart >= 0 && clearEnd > clearStart);
const clearWrapper = html.slice(clearStart, clearEnd);
assert.match(clearWrapper, /saveChatSessionSafely\(latest\)/);

assert.match(memoryEditor, /memoryMutationTracker\?\.begin\(s\.id,\s*previousMemories\)/);
assert.match(memoryEditor, /memoryMutationTracker\?\.rollback\(s\.id,\s*mutationVersion\)/);
assert.match(pinHandler, /memoryMutationTracker\?\.begin\(session\.id,\s*session\.memories\)/);
assert.match(pinHandler, /memoryMutationTracker\?\.rollback\(session\.id,\s*mutationVersion\)/);
// Cross-tab/device writes use the existing updated_at field as a compare-and-swap token.
const cloudSaveStart = html.indexOf("async function saveChatSessionToCloud(s, options = {})");
const cloudSaveEnd = html.indexOf("async function loadCloudChatSessions", cloudSaveStart);
assert.ok(cloudSaveStart >= 0 && cloudSaveEnd > cloudSaveStart);
const cloudSave = html.slice(cloudSaveStart, cloudSaveEnd);
assert.match(cloudSave, /select\('character_snapshot,updated_at'\)/);
assert.match(cloudSave, /eq\('updated_at', expectedUpdatedAt\)/);
assert.match(cloudSave, /s\.cloudUpdatedAt = sessionWrite\.data\.updated_at/);
assert.match(cloudSave, /此聊天已在其他分頁或裝置更新/);
assert.match(html, /cloudUpdatedAt:row\.updated_at \|\| null/);
assert.match(saveWrapper, /target\.cloudUpdatedAt = snapshot\.cloudUpdatedAt/);
assert.match(clearWrapper, /saveChatSessionSafely\(latest\)/);

// Other direct session metadata writes (pin/background) also use the same
// updated_at compare-and-swap token and refresh the local version on success.
assert.match(html, /eq\('updated_at',expectedUpdatedAt\)/);
assert.match(html, /session\.cloudUpdatedAt=saved\.updated_at/);
assert.match(html, /s\.cloudUpdatedAt=saved\.updated_at/);
assert.match(html, /item\.cloudUpdatedAt=updatedRow\.updated_at/);

console.log("Memory persistence, per-session serialization, cross-device CAS and rollback contracts passed.");
