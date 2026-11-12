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

test('memory album background integrations use registered lifecycle hooks, not render wrappers', () => {
  assert.match(appHtml, /register\('afterSingleConversation',\s*'memory-album\.single-background'/);
  assert.match(appHtml, /register\('afterGroupConversation',\s*'memory-album\.group-background'/);
  assert.doesNotMatch(appHtml, /const oldRenderConversation\s*=\s*renderConversation/);
  assert.doesNotMatch(appHtml, /const oldRenderGroupConversation\s*=\s*renderGroupConversation/);
});

test('single and group album overlays are dispatched through the lifecycle registry', () => {
  assert.match(appHtml, /register\('renderSingleOverlay',\s*'memory-album\.single-overlay'/);
  assert.match(appHtml, /register\('renderGroupOverlay',\s*'memory-album\.group-overlay'/);
  assert.match(appHtml, /lifecycle\.render\('renderSingleOverlay'/);
  assert.match(appHtml, /lifecycle\.render\('renderGroupOverlay'/);
  assert.doesNotMatch(appHtml, /const oldSingle\s*=\s*renderChatOverlay/);
  assert.doesNotMatch(appHtml, /const oldGroup\s*=\s*renderGroupChatOverlay/);
});

test('base conversation renderers dispatch lifecycle hooks after their existing render work', () => {
  assert.match(appHtml, /if \(route\.chatOverlay\) renderChatOverlay\(route\.chatOverlay\);\s*window\.PoyozzChatRenderLifecycle\?\.run\('afterSingleConversation'/);
  assert.match(appHtml, /applyGroupChatBackground\(\);\s*window\.PoyozzChatRenderLifecycle\?\.run\('afterGroupConversation'/);
});
