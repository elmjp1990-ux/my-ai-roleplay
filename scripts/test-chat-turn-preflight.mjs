import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
const activeCheck = source.indexOf('userClient.rpc("account_is_active")');
const keyRead = source.indexOf('Deno.env.get("OPENROUTER_API_KEY")');
const keyGuard = source.indexOf('if (!openRouterKey)');
const walletInit = source.indexOf('userClient.rpc("ensure_wallet_account")');
const reserve = source.indexOf('admin.rpc("reserve_chat_turn"');

assert.ok(activeCheck >= 0, "account active check must exist");
assert.ok(keyRead >= 0 && keyGuard > keyRead, "OpenRouter key preflight must exist");
assert.ok(
  activeCheck < keyRead && keyRead < walletInit && keyGuard < walletInit,
  "OpenRouter key must be checked after account validation but before wallet initialization",
);
assert.ok(
  keyGuard < reserve,
  "OpenRouter key must be checked before reserve_chat_turn can deduct wallet funds",
);
assert.match(
  source,
  /if\s*\(!openRouterKey\)\s*\{\s*return json\(\{\s*error:\s*"openrouter_not_configured",\s*retryAllowed:\s*true\s*\},\s*503\s*\);\s*\}/,
  "missing key must return a retryable 503 before any wallet reservation",
);
assert.equal(
  [...source.matchAll(/Deno\.env\.get\("OPENROUTER_API_KEY"\)/g)].length,
  1,
  "API key should be read once at preflight",
);

console.log("Story chat OpenRouter preflight contract passed: missing credentials fail before wallet initialization and reservation.");
