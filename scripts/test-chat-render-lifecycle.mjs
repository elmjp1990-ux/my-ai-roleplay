import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = fs.readFileSync(new URL('../chat-render-lifecycle.js', import.meta.url), 'utf8');

function createRegistry() {
  const errors = [];
  const window = {
    console: {
      error: (...args) => errors.push(args),
    },
  };
  vm.runInNewContext(source, { window, Map, Object, Number, TypeError });
  return { registry: window.PoyozzChatRenderLifecycle, errors };
}

test('registers hooks once per phase and stable key', () => {
  const { registry } = createRegistry();
  const calls = [];
  const first = registry.register('afterSingleConversation', 'memory-album', () => calls.push('first'));
  const duplicate = registry.register('afterSingleConversation', 'memory-album', () => calls.push('duplicate'));

  assert.equal(first.registered, true);
  assert.equal(duplicate.registered, false);
  assert.equal(registry.run('afterSingleConversation', {}).called, 1);
  assert.deepEqual(calls, ['first']);
});

test('runs hooks by descending priority and stable registration order', () => {
  const { registry } = createRegistry();
  const calls = [];
  registry.register('afterMessages', 'first', () => calls.push('first'));
  registry.register('afterMessages', 'high', () => calls.push('high'), { priority: 10 });
  registry.register('afterMessages', 'same-priority', () => calls.push('same-priority'), { priority: 10 });
  registry.register('afterMessages', 'low', () => calls.push('low'), { priority: -1 });

  registry.run('afterMessages', {});
  assert.deepEqual(calls, ['high', 'same-priority', 'first', 'low']);
});

test('isolates a failing hook and continues later hooks', () => {
  const { registry, errors } = createRegistry();
  const calls = [];
  registry.register('afterGroupConversation', 'broken', () => { throw new Error('expected test failure'); }, { priority: 2 });
  registry.register('afterGroupConversation', 'healthy', () => calls.push('healthy'));

  const result = registry.run('afterGroupConversation', {});
  assert.equal(result.errors, 1);
  assert.equal(result.called, 1);
  assert.deepEqual(calls, ['healthy']);
  assert.equal(errors.length, 1);
});

test('unsubscribe is idempotent and removes only its own registration', () => {
  const { registry } = createRegistry();
  let calls = 0;
  const subscription = registry.register('afterMessages', 'encounter', () => { calls += 1; });

  assert.equal(subscription.unsubscribe(), true);
  assert.equal(subscription.unsubscribe(), false);
  assert.equal(registry.run('afterMessages', {}).called, 0);
  assert.equal(calls, 0);
});

test('overlay renderer can claim a render and otherwise falls back to the base renderer', () => {
  const { registry } = createRegistry();
  const calls = [];
  registry.register('renderSingleOverlay', 'memory-album', (context) => {
    if (context.kind !== 'album') return false;
    calls.push('album');
    return true;
  });

  const handled = registry.render('renderSingleOverlay', { kind: 'album' }, () => calls.push('fallback'));
  assert.equal(handled.handled, true);
  assert.equal(handled.handler, 'memory-album');
  assert.deepEqual(calls, ['album']);

  const fallback = registry.render('renderSingleOverlay', { kind: 'search' }, () => {
    calls.push('fallback');
    return 'base-rendered';
  });
  assert.equal(fallback.fallback, true);
  assert.equal(fallback.value, 'base-rendered');
  assert.deepEqual(calls, ['album', 'fallback']);
});

test('a failing overlay extension does not block the base renderer', () => {
  const { registry } = createRegistry();
  registry.register('renderGroupOverlay', 'broken-extension', () => {
    throw new Error('overlay extension failed');
  });

  let fallbackCalls = 0;
  const result = registry.render('renderGroupOverlay', { kind: 'album' }, () => {
    fallbackCalls += 1;
    return 'base';
  });

  assert.equal(result.fallback, true);
  assert.equal(result.value, 'base');
  assert.equal(fallbackCalls, 1);
});

const appHtml = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const memoryAlbum = fs.readFileSync(new URL('../memory-album.js', import.meta.url), 'utf8');
const encounterScene = fs.readFileSync(new URL('../encounter-scene.js', import.meta.url), 'utf8');

test('memory album background integrations use registered lifecycle hooks, not render wrappers', () => {
  assert.match(memoryAlbum, /register\('afterSingleConversation',\s*'memory-album\.single-background'/);
  assert.match(memoryAlbum, /register\('afterGroupConversation',\s*'memory-album\.group-background'/);
  assert.doesNotMatch(appHtml, /const oldRenderConversation\s*=\s*renderConversation/);
  assert.doesNotMatch(appHtml, /const oldRenderGroupConversation\s*=\s*renderGroupConversation/);
});

test('single and group album overlays are dispatched through the lifecycle registry', () => {
  assert.match(memoryAlbum, /register\('renderSingleOverlay',\s*'memory-album\.single-overlay'/);
  assert.match(memoryAlbum, /register\('renderGroupOverlay',\s*'memory-album\.group-overlay'/);
  assert.match(appHtml, /lifecycle\.render\('renderSingleOverlay'/);
  assert.match(appHtml, /lifecycle\.render\('renderGroupOverlay'/);
  assert.doesNotMatch(appHtml, /const oldSingle\s*=\s*renderChatOverlay/);
  assert.doesNotMatch(appHtml, /const oldGroup\s*=\s*renderGroupChatOverlay/);
});

test('base conversation renderers dispatch lifecycle hooks after their existing render work', () => {
  assert.match(appHtml, /if \(route\.chatOverlay\) renderChatOverlay\(route\.chatOverlay\);\s*window\.PoyozzChatRenderLifecycle\?\.run\('afterSingleConversation'/);
  assert.match(appHtml, /applyGroupChatBackground\(\);\s*window\.PoyozzChatRenderLifecycle\?\.run\('afterGroupConversation'/);
});


test('encounter scene setup is registered as a conversation lifecycle hook', () => {
  assert.match(encounterScene, /register\('afterSingleConversation',\s*'encounter\.single-scene'/);
  assert.match(encounterScene, /register\('afterMessages',\s*'encounter\.progressive-dialogue'/);
  assert.match(encounterScene, /applyEncounterDialogue\(panel,session\)/);
  assert.match(appHtml, /function render\(\)[\s\S]*?classList\.toggle\('encounter-mode-active',\s*encounterRouteActive\)/);
});

test('base message renderer dispatches the afterMessages lifecycle phase', () => {
  assert.match(appHtml, /window\.PoyozzChatRenderLifecycle\?\.run\('afterMessages',\s*\{\s*session:\s*s,\s*panel:/);
});

test('encounter mode no longer wraps or replaces base render functions', () => {
  assert.doesNotMatch(appHtml, /const installEncounterRenderWrapper/);
  assert.doesNotMatch(appHtml, /const baseRenderConversation\s*=\s*renderConversation/);
  assert.doesNotMatch(appHtml, /const baseRenderMessages\s*=\s*renderMessages/);
  assert.doesNotMatch(appHtml, /renderConversation\s*=\s*wrappedRenderConversation/);
  assert.doesNotMatch(appHtml, /renderMessages\s*=\s*wrappedRenderMessages/);
});


const cityMap = fs.readFileSync(new URL('../city-map.js', import.meta.url), 'utf8');

test('city map exposes teardown and releases its timer, listeners and videos', () => {
  assert.match(cityMap, /destroy:\s*destroyActiveMap/);
  assert.match(cityMap, /clearInterval\(cityMapClock\)/);
  assert.match(cityMap, /removeEventListener\('visibilitychange',\s*onVisibilityChange\)/);
  assert.match(cityMap, /removeEventListener\('resize',\s*resizeHandler\)/);
  assert.match(cityMap, /characterVideoObserver\?\.unobserve\(video\)/);
  assert.match(cityMap, /releaseCharacterVideo\(video\)/);
  assert.match(cityMap, /locationModal\?\.remove\(\)/);
  assert.match(cityMap, /stage\.remove\(\)/);
  assert.match(appHtml, /const previousCardVideos[\s\S]*?window\.PoyozzCityMap\?\.destroy\?\.\(\);/);
});

test('memory album photo metadata is weakly held by mounted rows', () => {
  assert.match(memoryAlbum, /const urlCache\s*=\s*new WeakMap\(\)/);
  assert.match(memoryAlbum, /cards\.forEach\(\(card,index\)=>urlCache\.set\(renderedRows\[/);
  assert.match(memoryAlbum, /urlCache\.get\(row\)/);
  assert.doesNotMatch(memoryAlbum, /urlCache\.(?:set|get|delete)\(photo\.id/);
});

test('memory album pagination state uses a bounded LRU', () => {
  assert.match(memoryAlbum, /MAX_ALBUM_PAGE_STATES\s*=\s*8/);
  assert.match(memoryAlbum, /function getAlbumPageState\(key\)/);
  assert.match(memoryAlbum, /function rememberAlbumPageState\(key,pager\)/);
  assert.match(memoryAlbum, /while\(albumPageStates\.size>MAX_ALBUM_PAGE_STATES\)/);
  assert.match(memoryAlbum, /let pager=getAlbumPageState\(key\)/);
  assert.match(memoryAlbum, /rememberAlbumPageState\(key,pager\)/);
});
