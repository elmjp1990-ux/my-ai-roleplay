import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const html = readFileSync('index.html', 'utf8');
const migration = readFileSync(
  'supabase/migrations/20261031100000_character_illustration_storage.sql',
  'utf8'
);
const helperStart = html.indexOf('function planCharacterIllustrationGallerySync(');
const helperEnd = html.indexOf('\nasync function syncCharacterIllustrations', helperStart);
assert.notEqual(helperStart, -1, 'gallery planner must exist');
assert.ok(helperEnd > helperStart, 'gallery planner boundary must exist');
const helperSource = html.slice(helperStart, helperEnd);
const sandbox = { Set, Map, Error };
vm.runInNewContext(
  helperSource + '\nglobalThis.plan = planCharacterIllustrationGallerySync;',
  sandbox
);
const plan = sandbox.plan;
const plain = value => JSON.parse(JSON.stringify(value));
const oldRows = Array.from({ length: 5 }, (_, index) => ({
  id: 'old-' + (index + 1),
  storage_path: 'old/' + (index + 1) + '.webp',
  asset_type: 'gallery',
  sort_order: index + 1,
  display_name: '舊名稱' + (index + 1)
}));
const data = index => ({
  src: 'data:image/webp;base64,' + 'A'.repeat(16),
  name: '新名稱' + index
});

// Remove all five and upload five: every occupied slot is reused in place.
{
  const result = plan(oldRows, Array.from({ length: 5 }, (_, index) => data(index + 1)));
  assert.equal(result.additions.length, 5);
  assert.deepEqual(plain(result.additions.map(item => item.sortOrder)), [1, 2, 3, 4, 5]);
  assert.deepEqual(plain(result.additions.map(item => item.reusableRow?.id)), ['old-1', 'old-2', 'old-3', 'old-4', 'old-5']);
  assert.equal(result.obsoleteRows.length, 5);
}

// Remove all five and upload one: slot 1 is reused; four removed rows remain obsolete.
{
  const result = plan(oldRows, [data(1)]);
  assert.equal(result.additions.length, 1);
  assert.equal(result.additions[0].sortOrder, 1);
  assert.equal(result.additions[0].reusableRow?.id, 'old-1');
  assert.deepEqual(plain(result.obsoleteRows.map(row => row.id)), ['old-1', 'old-2', 'old-3', 'old-4', 'old-5']);
}

// Keep two and replace three: retained slots remain reserved; obsolete rows are reused.
{
  const retained = [
    { id: 'old-2', path: oldRows[1].storage_path, sortOrder: 2, name: '保留二' },
    { id: 'old-4', path: oldRows[3].storage_path, sortOrder: 4, name: '保留四' }
  ];
  const result = plan(oldRows, [...retained, data(1), data(2), data(3)]);
  assert.deepEqual(plain(result.additions.map(item => item.sortOrder)), [1, 3, 5]);
  assert.deepEqual(plain(result.additions.map(item => item.reusableRow?.id)), ['old-1', 'old-3', 'old-5']);
  assert.deepEqual(plain(result.retainedRows.map(row => row.id)), ['old-2', 'old-4']);
}

// Name-only edits must not allocate new slots or mark existing rows obsolete.
{
  const retained = oldRows.slice(0, 2).map((row, index) => ({
    id: row.id, path: row.storage_path, sortOrder: row.sort_order, name: '改名' + index
  }));
  const result = plan(oldRows, retained);
  assert.equal(result.additions.length, 0);
  assert.equal(result.obsoleteRows.length, 3);
  assert.deepEqual(plain(result.retainedItems.map(item => item.name)), ['改名0', '改名1']);
}

// The five-image cap remains enforced even when all old rows are present.
{
  const tooMany = [...oldRows.map(row => ({
    id: row.id, path: row.storage_path, sortOrder: row.sort_order, name: row.display_name
  })), data(6)];
  assert.throws(() => plan(oldRows, tooMany), /最多保留 5 張/);
}

const syncStart = html.indexOf('async function syncCharacterIllustrations(character,userId) {');
const syncEnd = html.indexOf('\nasync function compressCharacterAvatarVideo', syncStart);
assert.notEqual(syncStart, -1);
assert.ok(syncEnd > syncStart);
const syncSource = html.slice(syncStart, syncEnd);
const uploadLoop = syncSource.indexOf('for(const addition of galleryPlan.additions){\n      addition.path=await uploadCharacterIllustrationDataUrl');
const metadataLoop = syncSource.indexOf('for(const addition of galleryPlan.additions){\n      if(addition.reusableRow)');
const verifyBlock = syncSource.indexOf('const expectedGalleryNames=new Map');
const replacedCleanup = syncSource.indexOf('for(const change of replacedGallery)');
assert.ok(uploadLoop >= 0 && metadataLoop > uploadLoop,
  'all new gallery files must upload before gallery metadata is modified');
assert.ok(verifyBlock > metadataLoop && replacedCleanup > verifyBlock,
  'old replacement files may be cleaned only after new gallery metadata is verified');
assert.match(syncSource, /update\(\{\s*storage_path:addition\.path,[\s\S]*?sort_order:addition\.sortOrder/);
assert.match(syncSource, /reusableRow\.id/,
  'an obsolete row in the target slot must be reused instead of colliding with the unique index');
assert.match(syncSource, /rollbackGalleryChanges/,
  'partial metadata changes must have a rollback path');
assert.match(migration, /create unique index character_illustrations_gallery_position_uidx[\s\S]*?on public\.character_illustrations \(character_id, sort_order\) where asset_type = 'gallery'/,
  'the database uniqueness guard must remain enabled');

console.log('Passed: gallery replacement planning, slot reuse, name-only edits, five-image cap, upload ordering, and rollback guards.');
