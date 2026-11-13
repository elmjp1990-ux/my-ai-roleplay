#!/usr/bin/env node
/**
 * Legacy character image migration planner.
 *
 * Safe by default: this tool only reads Supabase and prints a migration plan.
 * It deliberately does not upload, update, delete, or apply SQL.
 *
 * Usage:
 *   SUPABASE_URL=http://127.0.0.1:54321 \
 *   SUPABASE_SERVICE_ROLE_KEY=... \
 *   node scripts/migrate-legacy-chat-images.mjs
 *
 * A later, separately reviewed implementation will add an explicit local-only
 * apply mode after this planner has passed fixture and disposable-local tests.
 */

import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const EXPECTED = Object.freeze({ characters: 8, currentSnapshots: 74, historicalSnapshots: 13 });
const DATA_URI = /^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/]+={0,2})$/i;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function parseImageDataUri(value) {
  if (typeof value !== "string") return null;
  const match = DATA_URI.exec(value);
  if (!match) return null;
  const mimeType = match[1].toLowerCase();
  const bytes = Buffer.from(match[2], "base64");
  if (!bytes.length || bytes.toString("base64").replace(/=+$/, "") !== match[2].replace(/=+$/, "")) return null;
  const extension = mimeType === "image/jpeg" ? "jpg" : mimeType.split("/")[1];
  return { mimeType, extension, bytes, sha256: createHash("sha256").update(bytes).digest("hex") };
}

function stableUuid(input) {
  const bytes = createHash("sha256").update(input).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}

export function buildMigrationPlan({ characters, sessions, strictCounts = true }) {
  if (!Array.isArray(characters) || !Array.isArray(sessions)) throw new TypeError("characters and sessions must be arrays");
  const byId = new Map();
  for (const character of characters) {
    if (!UUID.test(character?.id || "") || !UUID.test(character?.author_id || "")) {
      throw new Error("Invalid character or author UUID in source rows");
    }
    if (byId.has(character.id)) throw new Error("Duplicate character id: " + character.id);
    const parsed = parseImageDataUri(character.avatar_url);
    if (parsed) byId.set(character.id, { character, parsed });
  }

  const primaryAssets = [];
  for (const { character, parsed } of byId.values()) {
    const fileId = stableUuid(`poyozz-legacy-primary:${character.id}:${parsed.sha256}`);
    primaryAssets.push({
      characterId: character.id,
      authorId: character.author_id,
      sourceSha256: parsed.sha256,
      mimeType: parsed.mimeType,
      extension: parsed.extension,
      bytes: parsed.bytes.length,
      storagePath: `${character.author_id}/${character.id}/${fileId}.${parsed.extension}`,
      assetType: "primary",
      sortOrder: 0,
    });
  }

  const currentSnapshots = [];
  const historicalSnapshots = [];
  const matchedByCharacter = new Map([...byId.keys()].map(id => [id, 0]));
  const seenSessionIds = new Set();
  for (const session of sessions) {
    if (!UUID.test(session?.id || "")) throw new Error("Invalid chat_sessions.id");
    if (seenSessionIds.has(session.id)) throw new Error("Duplicate chat session id: " + session.id);
    seenSessionIds.add(session.id);
    const snapshot = session.character_snapshot;
    if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) continue;
    const image = snapshot.image;
    if (typeof image !== "string" || !image.startsWith("data:image/")) continue;
    const parsedSnapshot = parseImageDataUri(image);
    if (!parsedSnapshot) throw new Error(`Unsupported or malformed snapshot Data URI in session ${session.id}`);

    const exact = [...byId.entries()].find(([, item]) => item.character.avatar_url === image);
    if (exact) {
      const [characterId, item] = exact;
      if (session.character_id !== characterId) {
        throw new Error(`Snapshot ${session.id} image matches character ${characterId}, but session.character_id is ${session.character_id}`);
      }
      const asset = primaryAssets.find(row => row.characterId === characterId);
      currentSnapshots.push({
        sessionId: session.id,
        characterId,
        sourceSha256: item.parsed.sha256,
        expectedSnapshot: snapshot,
        storagePath: asset.storagePath,
        nextSnapshot: { ...snapshot, image: "", imagePath: asset.storagePath },
      });
      matchedByCharacter.set(characterId, matchedByCharacter.get(characterId) + 1);
    } else {
      // Historical images intentionally have no replacement path: their exact
      // visual version is being retired, not substituted with today's portrait.
      historicalSnapshots.push({
        sessionId: session.id,
        characterId: session.character_id,
        sourceSha256: parsedSnapshot.sha256,
        expectedSnapshot: snapshot,
        nextSnapshot: { ...snapshot, image: "" },
      });
    }
  }

  const unmatchedCurrent = [...matchedByCharacter].filter(([, count]) => count === 0).map(([id]) => id);
  if (strictCounts) {
    if (primaryAssets.length !== EXPECTED.characters ||
        currentSnapshots.length !== EXPECTED.currentSnapshots ||
        historicalSnapshots.length !== EXPECTED.historicalSnapshots) {
      throw new Error(`Inventory drift: expected 8/74/13, found ${primaryAssets.length}/${currentSnapshots.length}/${historicalSnapshots.length}`);
    }
    if (unmatchedCurrent.length) throw new Error("Some current character images have no matching chat snapshot: " + unmatchedCurrent.join(", "));
  }

  return {
    version: 1,
    mode: "dry-run",
    counts: {
      primaryImages: primaryAssets.length,
      currentSnapshots: currentSnapshots.length,
      historicalSnapshots: historicalSnapshots.length,
      totalSnapshotUpdates: currentSnapshots.length + historicalSnapshots.length,
      estimatedImageBytes: primaryAssets.reduce((sum, row) => sum + row.bytes, 0),
    },
    primaryAssets,
    currentSnapshots,
    historicalSnapshots,
    safety: {
      sourceRowsOnly: true,
      storageWrites: false,
      databaseWrites: false,
      deletes: false,
      historicalImageReplacement: false,
    },
  };
}

async function readTable(url, key, table, select) {
  const endpoint = new URL(`/rest/v1/${table}`, url);
  endpoint.searchParams.set("select", select);
  const response = await fetch(endpoint, {
    headers: { apikey: key, Authorization: `Bearer ${key}` },
  });
  if (!response.ok) throw new Error(`Read ${table} failed (${response.status}): ${await response.text()}`);
  return response.json();
}

async function main() {
  if (process.argv.includes("--apply")) {
    throw new Error("Apply mode is intentionally not implemented. This version is read-only dry-run only.");
  }
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (read-only dry-run credentials recommended).");
  const base = new URL(url);
  if (base.protocol !== "http:" && base.protocol !== "https:") throw new Error("Unsupported SUPABASE_URL protocol");
  const [characters, sessions] = await Promise.all([
    readTable(url, key, "characters", "id,author_id,avatar_url"),
    readTable(url, key, "chat_sessions", "id,character_id,character_snapshot"),
  ]);
  const plan = buildMigrationPlan({ characters, sessions });
  const safePlan = {
    ...plan,
    primaryAssets: plan.primaryAssets.map(({ ...row }) => ({ ...row, bytes: row.bytes })),
    currentSnapshots: plan.currentSnapshots.map(({ nextSnapshot, expectedSnapshot, ...row }) => row),
    historicalSnapshots: plan.historicalSnapshots.map(({ nextSnapshot, expectedSnapshot, ...row }) => row),
  };
  console.log(JSON.stringify(safePlan, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
