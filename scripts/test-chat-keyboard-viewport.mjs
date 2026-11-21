import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync("index.html", "utf8");
const encounterScene = fs.readFileSync("encounter-scene.js", "utf8");
const encounterHistory = fs.readFileSync("encounter-history.js", "utf8");
const style = html.match(/<style id="poyozz-chat-keyboard-viewport">([\s\S]*?)<\/style>/)?.[1] || "";
const match = html.match(/<script id="poyozz-chat-keyboard-viewport">([\s\S]*?)<\/script>/);
assert.ok(style, "keyboard viewport CSS must be present");
assert.ok(match, "keyboard viewport controller must be present");
const source = match[1];
assert.doesNotThrow(() => new Function(source), "keyboard viewport controller must parse");

assert.match(style, /body\.conversation main/);
assert.match(style, /body\.group-chat-page main/);
assert.match(encounterScene, /top:0!important;bottom:auto!important/);
assert.match(encounterScene, /height:78lvh!important/);
assert.match(encounterScene, /bottom:var\(--poyozz-encounter-composer-height,190px\)!important/);
assert.match(encounterScene, /bottom:0!important;max-height:calc\(var\(--poyozz-chat-viewport-height,100dvh\) - 72px\)!important/);
assert.match(encounterScene, /encounterTypingPulse/);
assert.match(encounterScene, /processEncounterSpriteBackdrop\(existingSprite,halfBodyImage\);\s*\}\s*\}else\{/,
  "The sprite source-change conditional must close before the no-art fallback branch");
assert.match(encounterScene, /Canonical Encounter presentation stylesheet/);
assert.doesNotMatch(html, /<style id="encounter-mode-render-conflict-fix">/,
  "Encounter visual overrides must not remain in index.html");
const htmlStyleBlocks=[...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(item=>item[1]).join("\n");
assert.doesNotMatch(htmlStyleBlocks, /encounter-mode-active|encounter-scene/,
  "No Encounter-specific visual selectors may remain in index.html style blocks");
assert.match(encounterScene, /\(r\+g\+b\)\/3>=140&&Math.max\(r,g,b\)-Math.min\(r,g,b\)<=42/);
assert.match(encounterScene, /background:transparent!important/);
assert.match(encounterScene, /image\.onerror=\(\)=>\{[\s\S]*?encounter-auto-bg-fallback/,
  "Portrait backdrop processing must gracefully mark cross-origin or canvas failures");
assert.match(html, /data-action="encounter-temporary-leave"/);
assert.match(html, /data-action="encounter-end-prompt"/);
assert.match(html, /data-action="encounter-end-confirm"/);
assert.match(html, /function conversationTypingIndicatorHTML/);
assert.match(html, /activeTurnInFlight\)\$\('messages'\)\.insertAdjacentHTML\('beforeend',conversationTypingIndicatorHTML\(\)\)/);
assert.match(html, /function conversationSuggestionsHTML/);
assert.match(html, /latestAssistantSuggestions/);
assert.match(encounterScene, /\.encounter-scene \.messages\{/);
assert.match(source, /baselineViewportHeight/);
assert.match(source, /syncKeyboardState/);
assert.match(source, /removeProperty\('--encounter-keyboard-offset'\)/);
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
  assert.equal(h.variables["--encounter-keyboard-offset"], undefined,
    "The shared controller must not set an Encounter keyboard offset; the viewport height is the sole layout source.");
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
  assert.equal(h.variables["--encounter-keyboard-offset"], undefined,
    "Encounter layout must not use a second keyboard offset after the shared viewport shrinks");
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

assert.match(html, /#storyRelationshipLabel\{display:inline-flex!important;align-items:center;margin:0!important;padding:0!important;border:0!important;background:transparent!important;box-shadow:none!important\}/);
assert.doesNotMatch(html, /character-status-label[^>]*>[\s\S]{0,120}公開中/);
assert.match(encounterScene, /chat-heading>\.row\.between\{align-items:flex-start!important;flex-wrap:wrap!important/);
assert.match(encounterScene, /composer-bottom-row\{display:flex!important;align-items:center!important;justify-content:space-between!important/);
assert.match(encounterScene, /composer-icon-button,[\s\S]{0,150}visibility:visible!important/);
assert.match(encounterScene, /chat-keyboard-open \.encounter-character-sprite\{height:78lvh!important/);
assert.match(encounterScene, /composer-bottom-row\{position:sticky!important;bottom:0!important/);
assert.match(encounterScene, /encounter-scene-label\{width:calc\(4em \+ 28px\)!important/);
assert.match(encounterScene, /encounter-identity-stack/);
assert.match(encounterScene, /controlsRow\.appendChild\(tag\)/);
assert.match(encounterScene, /stack\.appendChild\(affinityChip\)/);
assert.match(html, /chat-identity-copy[\s\S]{0,350}storyRelationshipLabel/);
assert.match(html, /poyozz-affinity-ui\.story\{padding:3px 4px!important;font-size:10px!important/);
assert.match(encounterHistory, /playerMessageSessions\.has\(row\.id\)/);
assert.match(encounterHistory, /excludedMessages\.has\(rawContent\)/);
assert.match(encounterHistory, /\.eq\('role','user'\)/);
