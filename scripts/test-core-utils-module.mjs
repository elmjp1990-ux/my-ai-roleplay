import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync('index.html', 'utf8');
const source = fs.readFileSync('core-utils.js', 'utf8');
const moduleTag = '<script src="./core-utils.js"></script>';
assert.ok(html.includes(moduleTag), 'Shared core utilities must be loaded.');
assert.ok(html.indexOf(moduleTag) < html.indexOf('<script>'),
  'Shared core utilities must load before the main application script.');
assert.match(html, /const \{ countChars, clone, isUuid \} = window\.PoyozzCoreUtils;/,
  'The main application must retain the existing helper names through a thin adapter.');
assert.doesNotMatch(html, /function isUuid\(value\)/,
  'The original inline UUID implementation must be removed after extraction.');

const window = {};
vm.runInNewContext(source, { window });
const utils = window.PoyozzCoreUtils;
assert.ok(Object.isFrozen(utils), 'The shared utility API must be immutable.');
assert.equal(utils.countChars('POYOZZ'), 6);
assert.equal(utils.countChars('你好'), 2);
assert.equal(utils.countChars('😀'), 1, 'Unicode code points must retain the existing spread-based counting behavior.');
assert.equal(utils.countChars(null), 4, 'Null coercion must remain unchanged.');
assert.equal(utils.isUuid('550e8400-e29b-41d4-a716-446655440000'), true);
assert.equal(utils.isUuid('550E8400-E29B-41D4-A716-446655440000'), true);
assert.equal(utils.isUuid('00000000-0000-0000-0000-000000000000'), false);
assert.equal(utils.isUuid('not-a-uuid'), false);
const original = { nested: { value: 1 }, rows: [1, 2] };
const copied = utils.clone(original);
assert.equal(JSON.stringify(copied), JSON.stringify(original));
copied.nested.value = 2;
assert.equal(original.nested.value, 1, 'clone must remain a detached JSON deep copy.');
assert.throws(() => utils.clone(undefined), 'Preserve JSON clone behavior for unsupported top-level values.');
assert.doesNotMatch(source, /document\.|localStorage|sessionStorage|fetch\(|\.from\(|\.rpc\(/,
  'Core utilities must not own browser, network, Supabase, or persistence side effects.');
console.log('Shared core utilities contract passed: Unicode length, strict UUID validation, JSON clone semantics, immutable API, and no side effects.');
