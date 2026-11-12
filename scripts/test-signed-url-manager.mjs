import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync('signed-url-manager.js', 'utf8');
function createManager(options) {
  const window = {};
  vm.runInNewContext(source, { window, Map, Date, TypeError });
  return window.PoyozzSignedUrlManager.create(options);
}
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};

test('coalesces concurrent requests and reuses cached signed URLs', async () => {
  const pending = deferred();
  let calls = 0;
  const manager = createManager({
    cacheTtlMs: 10000,
    createSignedUrl: async () => { calls++; return pending.promise; }
  });
  const first = manager.get('path/a');
  const second = manager.get('path/a');
  assert.equal(calls, 1);
  pending.resolve('https://storage.example/a');
  assert.deepEqual(await Promise.all([first, second]), [
    'https://storage.example/a', 'https://storage.example/a'
  ]);
  assert.equal(await manager.get('path/a'), 'https://storage.example/a');
  assert.equal(calls, 1);
});

test('forced refreshes coalesce and supersede older in-flight requests safely', async () => {
  const pending = [];
  let calls = 0;
  const manager = createManager({
    cacheTtlMs: 10000,
    createSignedUrl: () => {
      calls++;
      const task = deferred();
      pending.push(task);
      return task.promise;
    }
  });
  const oldRequest = manager.get('path/b');
  const forced = manager.get('path/b', { forceRefresh: true });
  const forcedAgain = manager.get('path/b', { forceRefresh: true });
  assert.equal(calls, 2);
  pending[0].resolve('https://storage.example/old');
  assert.equal(await oldRequest, 'https://storage.example/old');
  const joined = manager.get('path/b');
  assert.equal(calls, 2, 'old request cleanup must not remove the newer in-flight request');
  pending[1].resolve('https://storage.example/fresh');
  assert.deepEqual(await Promise.all([forced, forcedAgain, joined]), [
    'https://storage.example/fresh',
    'https://storage.example/fresh',
    'https://storage.example/fresh'
  ]);
  assert.equal(await manager.get('path/b'), 'https://storage.example/fresh');
  assert.equal(calls, 2);
});

test('a late superseded response cannot overwrite the winning cached URL', async () => {
  const pending = [];
  const manager = createManager({
    cacheTtlMs: 10000,
    createSignedUrl: () => {
      const task = deferred();
      pending.push(task);
      return task.promise;
    }
  });
  const late = manager.get('path/c');
  const winner = manager.get('path/c', { forceRefresh: true });
  pending[1].resolve('https://storage.example/winner');
  assert.equal(await winner, 'https://storage.example/winner');
  pending[0].resolve('https://storage.example/late');
  await late;
  assert.equal(await manager.get('path/c'), 'https://storage.example/winner');
});

test('does not cache or return a URL after the identity scope changes', async () => {
  let currentUid = 'user-a';
  let calls = 0;
  const manager = createManager({
    cacheTtlMs: 10000,
    isCurrent: context => currentUid === context.uid,
    createSignedUrl: async () => {
      calls++;
      await Promise.resolve();
      return 'https://storage.example/private';
    }
  });
  const pending = manager.get('user-a:path/photo.webp', { context: { uid: 'user-a' } });
  currentUid = 'user-b';
  assert.equal(await pending, null);
  currentUid = 'user-a';
  assert.equal(await manager.get('user-a:path/photo.webp', { context: { uid: 'user-a' } }),
    'https://storage.example/private');
  assert.equal(calls, 2);
});

test('invalidates cache entries and enforces an optional oldest-first size limit', async () => {
  const manager = createManager({
    cacheTtlMs: 10000,
    maxEntries: 2,
    createSignedUrl: async key => 'https://storage.example/' + key
  });
  await manager.get('a');
  await manager.get('b');
  await manager.get('c');
  await manager.get('b');
  manager.invalidate('b');
  await manager.get('b');
  assert.equal(await manager.get('a'), 'https://storage.example/a');
});
