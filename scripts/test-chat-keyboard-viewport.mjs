import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync("index.html", "utf8");
const encounterScene = fs.readFileSync("encounter-scene.js", "utf8");
const style = html.match(/<style id="poyozz-chat-keyboard-viewport">([\s\S]*?)<\/style>/)?.[1] || "";
const match = html.match(/<script id="poyozz-chat-keyboard-viewport">([\s\S]*?)<\/script>/);
assert.ok(style, "keyboard viewport CSS must be present");
assert.ok(match, "keyboard viewport controller must be present");
const source = match[1];
assert.doesNotThrow(() => new Function(source), "keyboard viewport controller must parse");

assert.match(style, /body\.conversation main/);
assert.match(style, /body\.group-chat-page main/);
assert.match(encounterScene, /top:var\(--poyozz-visual-viewport-top,0px\)!important/);
assert.match(encounterScene, /height:var\(--poyozz-chat-viewport-height,100dvh\)!important/);
assert.match(encounterScene, /bottom:var\(--poyozz-encounter-composer-height,190px\)!important/);
assert.match(encounterScene, /bottom:0!important;max-height:calc/);
assert.match(encounterScene, /encounterTypingPulse/);
assert.doesNotMatch(encounterScene, /trackEncounterKeyboard|encounter-keyboard-offset/);
assert.doesNotMatch(html, /<style id="encounter-mode-render-conflict-fix">/,
  "Encounter visual overrides must not remain in index.html");
const htmlStyleBlocks=[...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(item=>item[1]).join("\n");
assert.doesNotMatch(htmlStyleBlocks, /encounter-mode-active|encounter-scene/,
  "No Encounter-specific visual selectors may remain in index.html style blocks");
assert.match(encounterScene, /\\.encounter-scene \\.messages\\{/);
  "Encounter-specific final visual refinements must be centralized in encounter-scene.js");
assert.match(source, /baselineViewportHeight/);
assert.match(source, /syncKeyboardState/);
assert.match(source, /orientationchange/);
assert.match(source, /window\.visualViewport/);
assert.match(source, /addEventListener\('resize'/);
assert.match(source, /addEventListener\('scroll'/);
assert.match(source, /#messageInput, #groupMessageInput/);
assert.match(source, /ResizeObserver/);
assert.match(source, /scrollIntoView/);

function createHarness({ visualViewport = true, encounter = false } = {}) {
  const listeners = {};
  const viewportListeners = {};
  const variables = {};
  const classes = new Set(encounter ? ["encounter-mode-active"] : []);
  const raf = [];
  const composer = encounter ? { getBoundingClientRect: () => ({ height: 238 }) } : null;
  const viewport = visualViewport ? {
    height: 720,
    offsetTop: 0,
    addEventListener: (name, callback) => { viewportListeners[name] = callback; }
  } : null;
  class ResizeObserver {
    constructor(callback) { this.callback = callback; }
    observe() {}
    disconnect() {}
  }
  const document = {
    documentElement: {
      clientHeight: 800,
      style: {
        setProperty: (name, value) => { variables[name] = value; },
        removeProperty: name => { delete variables[name]; }
      }
    },
    body: { classList: {
      add: value => classes.add(value),
      remove: value => classes.delete(value),
      contains: value => classes.has(value)
    } },
    activeElement: null,
    querySelector: () => composer,
    addEventListener: (name, callback) => { listeners[name] = callback; }
  };
  const window = {
    innerHeight: 800,
    visualViewport: viewport,
    addEventListener: (name, callback) => { listeners["window:" + name] = callback; }
  };
  const context = {
    window, document, Number, Math, ResizeObserver,
    requestAnimationFrame: callback => { raf.push(callback); return raf.length; }
  };
  vm.runInNewContext(source, context);
  const flush = () => { while (raf.length) raf.shift()(); };
  return { listeners, viewportListeners, variables, classes, document, viewport, flush };
}

{
  const h = createHarness();
  assert.equal(h.variables["--poyozz-chat-viewport-height"], "720px");
  h.viewport.height = 410;
  h.viewportListeners.resize();
  h.flush();
  assert.equal(h.variables["--poyozz-chat-viewport-height"], "410px",
    "visualViewport resize must shrink single/group chat above the keyboard");
  const input = { matches: selector => selector.includes("#messageInput") };
  h.document.activeElement = input;
  h.listeners.focusin({ target: input });
  assert.ok(h.classes.has("chat-keyboard-open"), "focusing a chat composer with a shrunken viewport must mark keyboard state");
  h.viewport.height = 720;
  h.viewportListeners.resize();
  h.flush();
  assert.ok(!h.classes.has("chat-keyboard-open"),
    "Android back-button keyboard dismissal must clear keyboard state even while the textarea remains focused");
  assert.equal(h.document.activeElement, input, "keyboard dismissal must not require the textarea to blur");
  h.document.activeElement = { matches: () => false };
  h.listeners.focusout();
  h.flush();
  assert.ok(!h.classes.has("chat-keyboard-open"), "leaving the composer must clear keyboard state");
}

{
  const h = createHarness({ encounter: true });
  assert.equal(h.variables["--poyozz-encounter-composer-height"], "238px",
    "encounter composer height must be measured for dialogue clearance");
  h.viewport.height = 390;
  h.viewport.offsetTop = 12;
  h.viewportListeners.resize();
  h.flush();
  assert.equal(h.variables["--poyozz-chat-viewport-height"], "390px");
  assert.equal(h.variables["--poyozz-visual-viewport-top"], "12px");
  const input = {
    matches: selector => selector.includes("#messageInput"),
    scrollIntoView: () => { input.scrolled = true; }
  };
  h.document.activeElement = input;
  h.listeners.focusin({ target: input });
  h.flush();
  assert.ok(h.classes.has("chat-keyboard-open"));
  assert.ok(input.scrolled, "encounter input should be scrolled into the visible area on focus");
  h.viewport.height = 720;
  h.viewport.offsetTop = 0;
  h.viewportListeners.resize();
  h.flush();
  assert.ok(!h.classes.has("chat-keyboard-open"),
    "Encounter keyboard dismissal must restore the full-height character state without requiring blur");
  assert.equal(h.variables["--poyozz-chat-viewport-height"], "720px");
}

{
  const h = createHarness({ visualViewport: false });
  assert.equal(h.variables["--poyozz-chat-viewport-height"], "800px",
    "browsers without visualViewport must fall back to innerHeight");
}

console.log("Passed: single, group, and encounter chat keyboard viewport behavior.");
