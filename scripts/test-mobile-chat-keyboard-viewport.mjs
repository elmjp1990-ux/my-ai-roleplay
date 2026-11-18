import assert from "node:assert/strict";
import fs from "node:fs";

const html = fs.readFileSync("index.html", "utf8");
const viewportStyle = html.match(/<style id="poyozz-chat-keyboard-viewport">([\\s\\S]*?)<\\/style>/)?.[1] || "";
const viewportScript = html.match(/<script id="poyozz-chat-keyboard-viewport">([\\s\\S]*?)<\\/script>/)?.[1] || "";

assert.ok(viewportStyle, "keyboard viewport CSS must exist");
assert.ok(viewportScript, "keyboard viewport script must exist");
assert.match(viewportScript, /window\\.visualViewport/);
assert.match(viewportScript, /#messageInput, #groupMessageInput/);
assert.match(viewportScript, /chat-keyboard-open/);
assert.match(viewportStyle, /body\\.conversation main/);
assert.match(viewportStyle, /body\\.group-chat-page main/);
assert.match(viewportStyle, /body\\.encounter-mode-active \\.chat-main\\.encounter-scene/);
assert.match(viewportStyle, /--poyozz-visual-viewport-top/);
assert.match(viewportStyle, /--poyozz-encounter-composer-height/);
assert.match(viewportStyle, /chat-keyboard-open \\.chat-main\\.encounter-scene \\.composer/);
assert.match(viewportStyle, /chat-keyboard-open \\.chat-main\\.encounter-scene \\.messages/);
assert.match(viewportScript, /ResizeObserver/);
assert.match(viewportScript, /scrollIntoView/);

console.log("Mobile chat keyboard viewport contract passed for single, group, and encounter modes.");
