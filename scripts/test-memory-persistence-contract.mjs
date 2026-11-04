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
assert.match(memoryEditor, /s\.memories\s*=\s*previousMemories/);

console.log("Memory persistence, hydration, pin/edit/delete rollback, ordering and correction-priority contracts passed.");
