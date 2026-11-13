import fs from 'node:fs';
import assert from 'node:assert/strict';

const html = fs.readFileSync('index.html', 'utf8');
const start = html.indexOf('function canViewCharacterNsfw(character)');
const end = html.indexOf('\nfunction availableExploreTags()', start);
assert.ok(start >= 0 && end > start, 'NSFW visibility guard must exist');
const guard = html.slice(start, end);

assert.match(guard, /if \(character\?\.isNSFW !== true\) return true;/);
assert.match(guard, /const uid = currentUser\(\)\?\.uid \|\| null;/);
assert.match(guard, /if \(uid && uid === character\.authorId\) return true;/);
assert.match(guard, /if \(!uid\) return false;/);
assert.match(guard, /return currentUserCanViewNsfw\(\);/);
assert.doesNotMatch(guard, /cloudPublic\s*===\s*true/, 'cloudPublic must never bypass the age gate');

const exploreStart = html.indexOf('function exploreList()');
const exploreEnd = html.indexOf('\nfunction card(', exploreStart);
assert.ok(exploreStart >= 0 && exploreEnd > exploreStart, 'Explore list must exist');
assert.match(html.slice(exploreStart, exploreEnd), /canViewCharacterNsfw\(c\)/);

const accessStart = html.indexOf('function accessible(c)');
const accessEnd = html.indexOf('\nfunction characterIsOffline', accessStart);
assert.ok(accessStart >= 0 && accessEnd > accessStart, 'Character detail access guard must exist');
assert.match(html.slice(accessStart, accessEnd), /canViewCharacterNsfw\(c\)/);

console.log('Guest NSFW visibility contract passed.');
