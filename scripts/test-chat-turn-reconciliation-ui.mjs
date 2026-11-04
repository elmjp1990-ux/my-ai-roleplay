import fs from "node:fs";
import assert from "node:assert/strict";

const frontend = fs.readFileSync("index.html", "utf8");
const start = frontend.indexOf("if (result?.status === 'needs_reconciliation')");
const end = frontend.indexOf("if (result?.status !== 'settled' || invokeError)", start);

assert.ok(start >= 0 && end > start, "frontend must handle needs_reconciliation before generic retry handling");
const block = frontend.slice(start, end);
assert.match(block, /showDialog\('回覆狀態確認中'/, "unresolved turns must show a dedicated status dialog");
assert.match(block, /請先不要再次送出/, "the dialog must tell players not to resend an unresolved turn");
assert.match(block, /persist\(\);/, "the pending turn must be preserved for reconciliation");
assert.doesNotMatch(block, /delete s\.pendingTurn/, "the UI must not discard the stable turn identifiers");
console.log("Story turn reconciliation UI contract checks passed.");
