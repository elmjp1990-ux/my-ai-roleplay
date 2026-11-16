import assert from 'node:assert/strict';
import fs from 'node:fs';

const story = fs.readFileSync('supabase/functions/story-session/index.ts','utf8');
const encounter = fs.readFileSync('supabase/functions/encounter-session/index.ts','utf8');
const html = fs.readFileSync('index.html','utf8');

for (const [name,source] of [['story',story],['encounter',encounter]]) {
  assert.match(source,/from\("character_illustrations"\)/,name+' must look up primary Storage metadata');
  assert.match(source,/\.eq\("asset_type", "primary"\)/,name+' must use the primary asset');
  assert.match(source,/image: primaryIllustration\?\.storage_path \? "" : \(character\.avatar_url \|\| ""\)/,name+' must preserve legacy fallback while avoiding embedded images when Storage exists');
  assert.match(source,/imagePath: primaryIllustration\?\.storage_path \|\| ""/,name+' must persist stable path metadata');
}
assert.match(story,/character\.author_id === user\.id[\s\S]*storyQuery\.eq\("visibility", "public"\)/,
  'Story snapshots must not expose private opening messages to non-authors');
assert.match(encounter,/from\("character_stories"\)[\s\S]*\.eq\("visibility", "public"\)/,
  'Encounter snapshots must read only public opening messages');
assert.match(encounter,/opening: openingMessage/,
  'Encounter snapshots must preserve the public character opening');
assert.match(html,/async function hydrateCloudSessionCharacterImage\(s\)/);
assert.match(html,/getCharacterIllustrationSignedUrl\(path,\{forceRefresh:!!cached\}\)/);
assert.match(html,/cloudSessionImageUrlCache\.set\(key,\{url,expiresAt:Date\.now\(\)\+55\*60\*1000\}\)/);
assert.match(html,/forceRefresh:!!cached/);
assert.match(html,/data-character-illustration-path=.*c\.imagePath/);
assert.match(html,/priorSnapshot\.imagePath \? '' : \(character\?\.image \|\| priorSnapshot\.image \|\| ''\)/);
assert.match(html,/hydrateCloudSessionCharacterImage\(session\)/);
assert.match(html,/hydrateCloudSessionCharacterImage\(s\)/);
assert.match(html,/portraitPath&&uid&&s\.id/);
console.log('Chat snapshot image-path contract passed.');

const groupCreationMigration = fs.readFileSync(
  'supabase/migrations/20261116170000_preserve_group_character_avatar_snapshots.sql',
  'utf8',
);
assert.match(groupCreationMigration,/imagePath', COALESCE\(v_primary_illustration_path, ''\)/,
  'new group member snapshots must keep the primary illustration Storage path');
assert.match(groupCreationMigration,/image', CASE WHEN v_primary_illustration_path IS NOT NULL THEN '' ELSE COALESCE\(v_character\.avatar_url, ''\) END/,
  'new group member snapshots must keep the avatar URL when no primary illustration exists');
assert.match(groupCreationMigration,/c\.deleted_at IS NULL/,
  'the group creation eligibility check must continue rejecting soft-deleted characters');
assert.match(groupCreationMigration,/p_scene_mode IS DISTINCT FROM 'shared'/,
  'group creation must preserve the currently deployed shared-scene-only rule');
assert.match(groupCreationMigration,/c\.visibility = 'public'/,
  'group creation must preserve the currently deployed public-character-only rule');
assert.match(groupCreationMigration,/account_deletion_pending/,
  'group creation must continue rejecting accounts with pending deletion requests');
assert.match(groupCreationMigration,/cs\.visibility = 'public'/,
  'group opening snapshots must preserve the public-story visibility rule');
assert.match(groupCreationMigration,/ORDER BY cs\.created_at ASC/,
  'group snapshots must preserve the existing earliest public opening message behavior');
assert.match(groupCreationMigration,/CREATE TRIGGER characters_mark_existing_chat_snapshots_offline/,
  'soft-deleting a character must mark existing chat snapshots offline');
assert.match(groupCreationMigration,/UPDATE public\.chat_sessions cs[\s\S]*?\{deletedAt\}/,
  'single-chat snapshots must receive only offline metadata on soft delete');
assert.match(groupCreationMigration,/UPDATE public\.chat_group_members gm[\s\S]*?\{deletedAt\}/,
  'group-member snapshots must receive only offline metadata on soft delete');
assert.match(groupCreationMigration,/chat_sessions\.updated_at stable/,
  'the soft-delete trigger must not invalidate optimistic chat-sync versions');
assert.match(html,/async function signCharacterSnapshotPortraits\(members\)/,
  'group chats must be able to sign stable portrait paths from member snapshots');
assert.match(html,/characterIllustrationSignedUrlManager\.getMany\(unique\.map\(entry=>entry\.path\)\)/,
  'group snapshot portrait paths should be signed in a single batch');
assert.match(html,/snapshot\.imagePath\|\|snapshot\.primaryIllustrationPath/,
  'group list and group-open hydration must read the snapshotted image path');
assert.match(html,/const deletedAt=snap\?\.deletedAt\|\|found\.deletedAt\|\|null/,
  'single chat status must prefer the server-marked soft-delete state over a stale local character row');
assert.match(html,/m\.characterSnapshot\?\.deletedAt\|\|m\.character_snapshot\?\.deletedAt/,
  'group chat avatars must derive offline status from the immutable member snapshot');
assert.match(html,/member\.character_snapshot\?\.deletedAt\|\|member\.characterSnapshot\?\.deletedAt/,
  'group-list avatars must derive offline status from the immutable member snapshot');
assert.match(html,/character-status-dot.*離線／已下架/,
  'group avatars must expose an offline indicator when the snapshot is marked deleted');
assert.doesNotMatch(html,/\.character-avatar-status\.is-offline \.avatar,/,
  'offline status must not dim or hide the preserved character portrait');
assert.match(html,/\.group-avatar-stack > \.character-avatar-status\{position:absolute;display:block;width:25px;height:25px/,
  'group avatar status wrappers must retain a fixed portrait box');
assert.match(html,/\.group-avatar-stack > \.character-avatar-status:nth-child\(1\)\{left:0;top:0\}/,
  'the first group avatar wrapper must be positioned in the stack');
assert.match(html,/\.group-avatar-stack \.group-avatar-image\{position:absolute;left:0;top:0;width:100%;height:100%/,
  'group portrait images must fill their positioned status wrappers');
assert.match(html,/\.group-avatar-stack \.group-avatar-fallback\{position:absolute;left:0;top:0;width:100%;height:100%/,
  'group portrait fallbacks must fill their positioned status wrappers');

const retainedPortraitPolicy = fs.readFileSync(
  'supabase/migrations/20261116171000_allow_existing_chat_portrait_access.sql',
  'utf8',
);
assert.match(retainedPortraitPolicy,/cs\.user_id = \(SELECT auth\.uid\(\)\)/,
  'single-chat portrait access must be scoped to the authenticated chat owner');
assert.match(retainedPortraitPolicy,/cs\.deleted_at IS NULL/,
  'deleted single-chat sessions must not retain Storage access');
assert.match(retainedPortraitPolicy,/cs\.character_snapshot->>'imagePath' = objects\.name/,
  'single-chat access must be limited to the exact path in its trusted snapshot');
assert.match(retainedPortraitPolicy,/g\.owner_id = \(SELECT auth\.uid\(\)\)/,
  'group portrait access must be scoped to the authenticated group owner');
assert.match(retainedPortraitPolicy,/g\.deleted_at IS NULL/,
  'deleted groups must not retain Storage access');
assert.match(retainedPortraitPolicy,/gm\.character_snapshot->>'imagePath' = objects\.name/,
  'group access must be limited to the exact path in its member snapshot');
assert.match(retainedPortraitPolicy,/public\.account_is_active\(\)/,
  'existing-chat portrait reads must require an active authenticated account');

const softDeleteFunction = groupCreationMigration.match(
  /CREATE OR REPLACE FUNCTION public\.soft_delete_character\([\s\S]*?\$function\$;/,
)?.[0] || '';
assert.ok(softDeleteFunction, 'the migration must preserve and update the existing soft-delete RPC');
assert.doesNotMatch(softDeleteFunction,/updated_at\s*=\s*now\(\)/i,
  'soft_delete_character must not bump the chat session sync version');

const snapshotScenarios = fs.readFileSync(
  'supabase/tests/chat-snapshot-avatar-scenarios.sql',
  'utf8',
);
assert.match(snapshotScenarios,/DELETE FROM public\.character_illustrations WHERE character_id = v_character/,
  'group snapshot-only access must be tested without a matching illustration metadata row');
assert.match(snapshotScenarios,/anonymous viewers unexpectedly received access to an NSFW portrait/,
  'the original public Storage policy must retain its NSFW gate');
