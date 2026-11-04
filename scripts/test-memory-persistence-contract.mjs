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

console.log("Memory persistence, hydration, ordering and correction-priority contracts passed.");
