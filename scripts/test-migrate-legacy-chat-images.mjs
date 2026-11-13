import test from "node:test";
import assert from "node:assert/strict";
import { buildMigrationPlan, parseImageDataUri } from "./migrate-legacy-chat-images.mjs";

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
