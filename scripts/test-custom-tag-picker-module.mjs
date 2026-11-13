import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const moduleSource = fs.readFileSync('custom-tag-picker.js', 'utf8');

const moduleTag = '<script src="./custom-tag-picker.js"></script>';
assert.ok(html.includes(moduleTag), 'Custom tag picker module must be loaded.');
assert.ok(html.indexOf(moduleTag) < html.indexOf('function refreshCustomTagPicker()'),
  'Custom tag picker must load before its app adapter.');

const start = html.indexOf('function refreshCustomTagPicker()');
const end = html.indexOf('/* Delegated click actions */', start);
assert.ok(start >= 0 && end > start && end - start < 600,
  'index.html must retain only a thin custom-tag-picker adapter.');
const adapter = html.slice(start, end);
assert.match(adapter, /window\.PoyozzCustomTagPicker/);
assert.match(adapter, /picker\.bind\(dependencies\)/);
assert.match(adapter, /picker\.render\(dependencies\)/);

assert.match(moduleSource, /global\.PoyozzCustomTagPicker = Object\.freeze/);
assert.match(moduleSource, /function render\(dependencies\)/);
assert.match(moduleSource, /function bind\(dependencies\)/);
assert.match(moduleSource, /if \(bound\) return/);
for (const contract of [
  'input[name="tagSearch"]',
  '#customTagList',
  '#customTagResults',
  '#customTagSelected',
  '#customTagCount',
  'toLocaleLowerCase(\'zh-Hant\')',
  'data-action="toggle-custom-tag"',
  'data-action="add-custom-tag"',
  'checked.length>=5',
  '角色最多選擇5個標籤。',
  '沒有符合的標籤，可新增這個標籤。',
  '尚未選擇標籤'
]) {
  assert.ok(moduleSource.includes(contract), 'Custom tag picker contract missing: ' + contract);
}
assert.doesNotMatch(moduleSource, /\.from\(|\.rpc\(|\.insert\(|\.update\(|\.delete\(/);
console.log('Custom tag picker module extraction and UI contract passed.');
