import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const generatedStart = html.indexOf('  // Creator notice prompts guide AI generation only; never render raw instructions to players.');
const generatedEnd = html.indexOf('  const memberSwitch=', generatedStart);

assert.ok(generatedStart >= 0 && generatedEnd > generatedStart, 'Phone notification rendering block must exist');
const phoneBlock = html.slice(generatedStart, generatedEnd);

assert.match(phoneBlock, /const generated=isGroup\?/);
assert.match(phoneBlock, /const notices=Array\.isArray\(generated\)/);
assert.match(phoneBlock, /const noticeLines=notices\.map/);
assert.match(phoneBlock, /目前還沒有新的手機通知/);
assert.doesNotMatch(phoneBlock, /noticePrompts|settings\.notices|\.\.\.prompts/, 'Creator-only notice prompts must never be rendered as player-facing phone content');

console.log('Phone notification UI hides creator prompts and renders generated notices only.');
