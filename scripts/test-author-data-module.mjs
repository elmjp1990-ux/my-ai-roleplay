import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('author-data.js', 'utf8');
const context = { window: {} };
vm.runInNewContext(source, context);
const data = context.window.PoyozzAuthorData;
assert.equal(typeof data?.fetchLatestCharactersByAuthor, 'function');
assert.equal(typeof data?.fetchPublicCharacterPage, 'function');

const calls = [];
const client = {
  async rpc(name, args) {
    calls.push({ name, ids: args.p_author_ids });
    return {
      error: null,
      data: args.p_author_ids.flatMap(authorId => authorId === 'author-a'
        ? Array.from({ length: 5 }, (_, index) => ({
          author_id: authorId, character_data: { id: authorId + '-' + index },
        }))
        : authorId === 'author-c'
          ? [{ author_id: authorId, character_data: { id: 'author-c-1' } }]
          : []),
    };
  },
};
const ids = Array.from({ length: 11 }, (_, index) => 'author-' + String.fromCharCode(97 + index));
ids.push('author-a');
const latest = await data.fetchLatestCharactersByAuthor(client, ids);
assert.equal(calls.length, 2, 'author IDs must be batched in groups of ten');
assert.equal(calls[0].ids.length, 10);
assert.equal(calls[1].ids.length, 1, 'duplicate author IDs must be removed before batching');
assert.equal(latest.get('author-a').length, 5);
assert.equal(latest.get('author-c').length, 1);
assert.equal(latest.get('author-b').length, 0);
assert.equal((await data.fetchLatestCharactersByAuthor(null, ids)).size, 0);

const queryCalls = [];
const queryClient = {
  from(table) {
    queryCalls.push(['from', table]);
    const query = {
      select(value) { queryCalls.push(['select', value]); return this; },
      eq(column, value) { queryCalls.push(['eq', column, value]); return this; },
      is(column, value) { queryCalls.push(['is', column, value]); return this; },
      order(column, options) { queryCalls.push(['order', column, options]); return this; },
      async range(from, to) {
        queryCalls.push(['range', from, to]);
        return { error: null, data: [{ id: 'character-1' }, { id: 'character-2' }] };
      },
    };
    return query;
  },
};
const page = await data.fetchPublicCharacterPage(queryClient, 'author-a', 10, 2);
assert.equal(page.rows.length, 2);
assert.equal(page.hasMore, true);
assert.deepEqual(queryCalls.filter(call => call[0] === 'eq'), [
  ['eq', 'author_id', 'author-a'], ['eq', 'visibility', 'public'],
]);
assert.deepEqual(queryCalls.find(call => call[0] === 'is'), ['is', 'deleted_at', null]);
assert.deepEqual(queryCalls.find(call => call[0] === 'range'), ['range', 10, 11]);

const errorClient = {
  from() {
    return {
      select() { return this; }, eq() { return this; }, is() { return this; }, order() { return this; },
      async range() { return { data: null, error: { message: 'denied' } }; },
    };
  },
};
await assert.rejects(
  () => data.fetchPublicCharacterPage(errorClient, 'author-a', 0, 10),
  /denied/,
);

console.log('Author data adapter contract passed.');
