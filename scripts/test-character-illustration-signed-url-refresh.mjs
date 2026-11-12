import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const html = readFileSync('index.html', 'utf8');
const helperStart = html.indexOf('const characterIllustrationSignedUrlCache = new Map();');
const helperEnd = html.indexOf('const characterIllustrationMetadataInflight', helperStart);
const refreshStart = html.indexOf('async function refreshCharacterIllustrationSignedUrl(storagePath) {');
const refreshEnd = html.indexOf('\n}', refreshStart) + 2;

assert.notEqual(helperStart, -1, 'signed URL cache helper must exist');
assert.notEqual(helperEnd, -1, 'signed URL helper block must have an end');
assert.notEqual(refreshStart, -1, 'signed URL refresh helper must exist');
assert.ok(refreshEnd > refreshStart, 'signed URL refresh helper must be complete');

let createCalls = 0;
const sandbox = {
  window: {
    mySupabase: {
      storage: {
        from(bucket) {
          assert.equal(bucket, 'character-illustrations');
          return {
            async createSignedUrl(path, expiresIn) {
              assert.equal(path, 'owner/character/illustration.webp');
              assert.equal(expiresIn, 3600);
              createCalls += 1;
              return { data: { signedUrl: 'https://storage.example/signed-' + createCalls }, error: null };
            }
          };
        }
      }
    }
  },
  Map,
  Date,
  Error
};

const source = html.slice(helperStart, helperEnd) + '\n' +
  html.slice(refreshStart, refreshEnd) +
  '\nglobalThis.testApi = { getCharacterIllustrationSignedUrl, refreshCharacterIllustrationSignedUrl };';
vm.runInNewContext(source, sandbox);

const path = 'owner/character/illustration.webp';
const first = await sandbox.testApi.getCharacterIllustrationSignedUrl(path);
const cached = await sandbox.testApi.getCharacterIllustrationSignedUrl(path);
assert.equal(first, cached, 'normal reads should reuse the cached signed URL');
assert.equal(createCalls, 1, 'normal cache hit should not create another signed URL');

const refreshed = await sandbox.testApi.refreshCharacterIllustrationSignedUrl(path);
assert.notEqual(refreshed, first, 'refresh after an image error must produce a fresh signed URL');
assert.equal(createCalls, 2, 'forced refresh must bypass the cached signed URL');

console.log('Passed: expired character illustration URLs are force-refreshed instead of reusing stale cache entries.');
