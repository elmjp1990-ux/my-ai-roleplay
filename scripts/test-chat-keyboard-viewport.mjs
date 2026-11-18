import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync("index.html", "utf8");
const match = html.match(/<script id="poyozz-chat-keyboard-viewport">([\\s\\S]*?)<\\/script>/);
assert.ok(match, "keyboard viewport controller must be present");
const source = match[1];
assert.doesNotThrow(() => new Function(source), "keyboard viewport controller must parse");
assert.match(html, /body\\.conversation main,body\\.group-chat-page main[\\s\\S]*?--poyozz-chat-viewport-height/);
assert.match(html, /body\\.conversation \\.chat-layout,body\\.group-chat-page \\.chat-layout[\\s\\S]*?height:100%/);
assert.match(source, /window\\.visualViewport/);
assert.match(source, /addEventListener\\('resize'/);
assert.match(source, /addEventListener\\('scroll'/);
assert.match(source, /#messageInput, #groupMessageInput/);

function createHarness(withVisualViewport = true) {
  const listeners = {};
  const viewportListeners = {};
  const variables = {};
  const classes = new Set();
  const raf = [];
  const visualViewport = withVisualViewport ? {
    height: 720,
    addEventListener: (name, callback) => { viewportListeners[name] = callback; }
  } : null;
  const document = {
    documentElement: { clientHeight: 800, style: { setProperty: (name, value) => { variables[name] = value; } } },
    body: { classList: { add: value => classes.add(value), remove: value => classes.delete(value) } },
    activeElement: null,
    addEventListener: (name, callback) => { listeners[name] = callback; }
  };
  const window = {
    innerHeight: 800,
    visualViewport,
    addEventListener: (name, callback) => { listeners["window:" + name] = callback; }
  };
  const context = {
    window, document, Number, Math,
    requestAnimationFrame: callback => { raf.push(callback); return raf.length; }
  };
  vm.runInNewContext(source, context);
  const flush = () => { while (raf.length) raf.shift()(); };
  return { listeners, viewportListeners, variables, classes, document, visualViewport, flush };
}

{
  const h = createHarness(true);
  assert.equal(h.variables["--poyozz-chat-viewport-height"], "720px");
  h.visualViewport.height = 410;
  h.viewportListeners.resize();
  h.flush();
  assert.equal(h.variables["--poyozz-chat-viewport-height"], "410px",
    "visualViewport resize must shrink the chat shell above the keyboard");
  const input = { matches: selector => selector.includes("#messageInput") };
  h.listeners.focusin({ target: input });
  assert.ok(h.classes.has("chat-keyboard-open"), "focusing the single-chat composer must mark keyboard state");
  h.document.activeElement = { matches: () => false };
  h.listeners.focusout();
  h.flush();
  assert.ok(!h.classes.has("chat-keyboard-open"), "leaving the composer must clear keyboard state");
}

{
  const h = createHarness(false);
  assert.equal(h.variables["--poyozz-chat-viewport-height"], "800px",
    "browsers without visualViewport must fall back to innerHeight");
}

console.log("Passed: single/group chat viewport sizing, Android keyboard resize, focus state, and fallback viewport.");
