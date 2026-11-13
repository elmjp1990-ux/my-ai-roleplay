import test from "node:test";
import assert from "node:assert/strict";
import { buildMigrationPlan, parseImageDataUri } from "./migrate-legacy-chat-images.mjs";
import { applyLegacyImageMigration, createResumableManifest, hashJson } from "./legacy-image-migration-runner.mjs";

const uuid = n => `00000000-0000-4000-8000-${String(n).padStart(12,"0")}`;
const data = (text, mime="image/png") => `data:${mime};base64,${Buffer.from(text).toString("base64")}`;

function fixture() {
  const characters = Array.from({length:8},(_,i)=>({
    id:uuid(i+1),author_id:uuid(100+i),avatar_url:data("current-"+i),
  }));
  const sessions=[];
  let id=1;
  for(let i=0;i<8;i++) {
    const count=i<6?9:10;
    for(let j=0;j<count;j++) sessions.push({
      id:uuid(1000+id++),character_id:characters[i].id,
      character_snapshot:{id:characters[i].id,name:"Role "+i,image:characters[i].avatar_url,opening:"Keep me"},
    });
  }
  // 74 exact current snapshots above; 13 distinct historical image versions.
  for(let i=0;i<13;i++) sessions.push({
    id:uuid(2000+i),character_id:characters[i%8].id,
    character_snapshot:{id:characters[i%8].id,name:"Role",image:data("historical-"+i),opening:"Preserve text"},
  });
  return {characters,sessions};
}

test("parses supported image data URIs and rejects malformed payloads",()=>{
  assert.equal(parseImageDataUri(data("x","image/jpeg")).extension,"jpg");
  assert.equal(parseImageDataUri(data("x","image/webp")).mimeType,"image/webp");
  assert.equal(parseImageDataUri("data:image/gif;base64,AAAA"),null);
  assert.equal(parseImageDataUri("data:image/png;base64,%%%"),null);
});

test("plans exactly 8 primary images, 74 path snapshots, and 13 historical clears",()=>{
  const plan=buildMigrationPlan(fixture());
  assert.deepEqual(plan.counts,{
    primaryImages:8,currentSnapshots:74,historicalSnapshots:13,totalSnapshotUpdates:87,
    estimatedImageBytes:plan.counts.estimatedImageBytes,
  });
  assert.equal(plan.primaryAssets.every(x=>x.assetType==="primary"&&x.sortOrder===0),true);
  assert.equal(plan.currentSnapshots.every(x=>x.nextSnapshot.image===""&&x.nextSnapshot.imagePath===x.storagePath),true);
  assert.equal(plan.historicalSnapshots.every(x=>x.nextSnapshot.image===""&&!Object.hasOwn(x.nextSnapshot,"imagePath")),true);
  assert.equal(plan.currentSnapshots.every(x=>x.nextSnapshot.opening==="Keep me"),true);
  assert.equal(plan.historicalSnapshots.every(x=>x.nextSnapshot.opening==="Preserve text"),true);
  assert.equal(plan.safety.databaseWrites,false);
  assert.equal(plan.safety.storageWrites,false);
});

test("is deterministic and safe to rerun",()=>{
  const input=fixture();
  const first=buildMigrationPlan(input);
  const second=buildMigrationPlan(input);
  assert.deepEqual(first.primaryAssets.map(x=>x.storagePath),second.primaryAssets.map(x=>x.storagePath));
});

test("fails closed on count drift and mismatched current snapshot ownership",()=>{
  const input=fixture();
  assert.throws(()=>buildMigrationPlan({...input,sessions:input.sessions.slice(0,-1)}),/Inventory drift/);
  const bad=fixture();
  bad.sessions[0].character_id=uuid(999);
  assert.throws(()=>buildMigrationPlan(bad),/but session.character_id/);
});

test("fails closed on unsupported historical image formats",()=>{
  const input=fixture();
  input.sessions.at(-1).character_snapshot.image="data:image/gif;base64,AAAA";
  assert.throws(()=>buildMigrationPlan(input),/Unsupported or malformed/);
});


test("resumable runner recovers after interruption without duplicate objects or metadata", async () => {
  const input = fixture();
  const plan = buildMigrationPlan(input);
  const manifest = createResumableManifest(plan, input.characters);
  assert.equal(JSON.stringify(manifest).includes("data:image/"), false);

  const characters = new Map(input.characters.map(row => [row.id, structuredClone(row)]));
  const sessions = new Map(input.sessions.map(row => [row.id, structuredClone(row)]));
  const objects = new Map();
  const metadata = new Map();
  let uploadCount = 0;
  let metadataInsertCount = 0;
  let snapshotWrites = 0;
  let interrupt = true;
  const adapter = {
    parseDataUri: parseImageDataUri,
    async getCharacter(id) { return structuredClone(characters.get(id)); },
    async getSession(id) { return structuredClone(sessions.get(id)); },
    async ensureObject(asset) {
      const existing = objects.get(asset.storagePath);
      if (existing) {
        assert.equal(existing.sha256, asset.sourceSha256);
        return;
      }
      assert.ok(asset.bytes, "source bytes must be available before the avatar is cleared");
      assert.equal(parseImageDataUri(data("unused")).extension, "png");
      const sha256 = (await import("node:crypto")).createHash("sha256").update(asset.bytes).digest("hex");
      assert.equal(sha256, asset.sourceSha256);
      objects.set(asset.storagePath, { sha256, bytes: Buffer.from(asset.bytes) });
      uploadCount++;
    },
    async ensureMetadata(asset) {
      const existing = metadata.get(asset.storagePath);
      if (existing) {
        assert.equal(existing.character_id, asset.characterId);
        assert.equal(existing.author_id, asset.authorId);
        assert.equal(existing.asset_type, "primary");
        return;
      }
      metadata.set(asset.storagePath, {
        character_id: asset.characterId, author_id: asset.authorId,
        storage_path: asset.storagePath, asset_type: "primary", sort_order: 0,
      });
      metadataInsertCount++;
    },
    async updateSnapshotIfUnchanged({ sessionId, characterId, expectedSnapshot, nextSnapshot }) {
      const row = sessions.get(sessionId);
      if (!row || row.character_id !== characterId || hashJson(row.character_snapshot) !== hashJson(expectedSnapshot)) return false;
      row.character_snapshot = structuredClone(nextSnapshot);
      snapshotWrites++;
      if (interrupt && snapshotWrites === 4) {
        interrupt = false;
        throw new Error("simulated process interruption");
      }
      return true;
    },
    async clearCharacterAvatarIfUnchanged({ characterId, authorId, expectedImageSha256 }) {
      const row = characters.get(characterId);
      if (!row || row.author_id !== authorId || (await import("node:crypto")).createHash("sha256").update(row.avatar_url).digest("hex") !== expectedImageSha256) return false;
      row.avatar_url = null;
      return true;
    },
  };

  const checkpoints = [];
  await assert.rejects(
    applyLegacyImageMigration({ manifest, adapter, persist: state => checkpoints.push(state) }),
    /simulated process interruption/,
  );
  assert.equal(manifest.status, "running");
  assert.equal(manifest.currentSnapshots.filter(x => x.completed).length, 3);
  await applyLegacyImageMigration({ manifest, adapter, persist: state => checkpoints.push(state) });

  assert.equal(manifest.status, "complete");
  assert.equal(uploadCount, 8);
  assert.equal(metadataInsertCount, 8);
  assert.equal(snapshotWrites, 87);
  assert.equal([...characters.values()].every(x => x.avatar_url == null), true);
  assert.equal([...sessions.values()].filter(x => x.character_snapshot.imagePath).length, 74);
  assert.equal([...sessions.values()].filter(x => x.character_snapshot.image === "").length, 87);
  assert.equal(metadata.size, 8);
  assert.ok(checkpoints.length > 90);

  const before = { uploadCount, metadataInsertCount, snapshotWrites };
  await applyLegacyImageMigration({ manifest, adapter });
  assert.deepEqual({ uploadCount, metadataInsertCount, snapshotWrites }, before);
});
