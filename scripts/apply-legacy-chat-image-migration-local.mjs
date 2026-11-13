import { createHash } from "node:crypto";
import { parseImageDataUri } from "./migrate-legacy-chat-images.mjs";
import { applyLegacyImageMigration } from "./legacy-image-migration-runner.mjs";

const BUCKET = "character-illustrations";

export function assertLocalSupabaseUrl(value) {
  const url = new URL(value);
  const localHosts = new Set(["localhost", "127.0.0.1", "::1", "[::1]"]);
  if (url.protocol !== "http:" || !localHosts.has(url.hostname) || url.port !== "54321") {
    throw new Error("Apply is restricted to http://localhost:54321 (or loopback equivalent). Hosted Supabase is never an apply target.");
  }
  return url;
}

function encodedPath(path) {
  return path.split("/").map(encodeURIComponent).join("/");
}

export function createLocalSupabaseAdapter({ url, serviceRoleKey, fetchImpl = fetch }) {
  const base = assertLocalSupabaseUrl(url);
  if (!serviceRoleKey) throw new Error("Missing local Supabase service-role key");
  const headers = {
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
  };
  const endpoint = (path) => new URL(path.replace(/^\//, ""), base).toString();

  async function request(path, options = {}) {
    const response = await fetchImpl(endpoint(path), {
      ...options,
      headers: { ...headers, ...(options.headers || {}) },
    });
    if (!response.ok) {
      const body = await response.text();
      throw new Error(`Local Supabase request failed (${response.status}) for ${path}: ${body.slice(0, 800)}`);
    }
    return response;
  }

  async function getOne(table, filters, select) {
    const url = new URL(endpoint(`rest/v1/${table}`));
    url.searchParams.set("select", select);
    url.searchParams.set("limit", "2");
    for (const [key, value] of Object.entries(filters)) url.searchParams.set(key, value);
    const response = await fetchImpl(url, { headers });
    if (!response.ok) throw new Error(`Read ${table} failed (${response.status}): ${await response.text()}`);
    const rows = await response.json();
    if (!Array.isArray(rows)) throw new Error(`Read ${table} returned an unexpected payload`);
    if (rows.length > 1) throw new Error(`Expected at most one ${table} row`);
    return rows[0] ?? null;
  }

  async function downloadObject(path) {
    const response = await fetchImpl(endpoint(`storage/v1/object/authenticated/${BUCKET}/${encodedPath(path)}`), { headers });
    if (!response.ok) {
      const body = await response.text();
      if (response.status === 404 || /object not found/i.test(body)) return null;
      throw new Error(`Storage verification failed (${response.status}): ${body.slice(0, 800)}`);
    }
    return Buffer.from(await response.arrayBuffer());
  }

  return {
    parseDataUri: parseImageDataUri,

    async getCharacter(id) {
      return getOne("characters", { id: `eq.${id}` }, "id,author_id,avatar_url");
    },

    async getSession(id) {
      return getOne("chat_sessions", { id: `eq.${id}` }, "id,character_id,character_snapshot");
    },

    async ensureObject(asset) {
      let existing = await downloadObject(asset.storagePath);
      if (existing) {
        const hash = createHash("sha256").update(existing).digest("hex");
        if (hash !== asset.sourceSha256) throw new Error(`Existing Storage object has a different hash: ${asset.storagePath}`);
        return;
      }
      if (!asset.bytes) throw new Error(`Storage object is missing and source avatar is already cleared: ${asset.storagePath}`);
      const response = await fetchImpl(endpoint(`storage/v1/object/${BUCKET}/${encodedPath(asset.storagePath)}`), {
        method: "POST",
        headers: { ...headers, "Content-Type": asset.mimeType, "x-upsert": "false" },
        body: asset.bytes,
      });
      const uploadError = response.ok ? null : (await response.text()).slice(0, 800);
      // Confirm the final bytes even if an upload raced with an existing object.
      existing = await downloadObject(asset.storagePath);
      if (!existing || createHash("sha256").update(existing).digest("hex") !== asset.sourceSha256) {
        throw new Error(`Storage upload/verification failed for ${asset.storagePath}: ${uploadError || "downloaded bytes do not match"}`);
      }
    },

    async ensureMetadata(asset) {
      const query = new URL(endpoint("rest/v1/character_illustrations"));
      query.searchParams.set("select", "character_id,author_id,storage_path,asset_type,sort_order");
      query.searchParams.set("storage_path", `eq.${asset.storagePath}`);
      const read = await fetchImpl(query, { headers });
      if (!read.ok) throw new Error(`Metadata read failed (${read.status}): ${await read.text()}`);
      const rows = await read.json();
      if (rows.length) {
        const row = rows[0];
        if (rows.length !== 1 || row.character_id !== asset.characterId ||
            row.author_id !== asset.authorId || row.asset_type !== "primary" || row.sort_order !== 0) {
          throw new Error(`Conflicting metadata exists for ${asset.storagePath}`);
        }
        return;
      }
      const inserted = await fetchImpl(endpoint("rest/v1/character_illustrations"), {
        method: "POST",
        headers: { ...headers, "Content-Type": "application/json", Prefer: "return=representation" },
        body: JSON.stringify({
          character_id: asset.characterId,
          author_id: asset.authorId,
          storage_path: asset.storagePath,
          asset_type: "primary",
          sort_order: 0,
        }),
      });
      const insertError = inserted.ok ? null : (await inserted.text()).slice(0, 500);
      // Verify metadata after both normal insert and conflict/retry paths.
      const reread = await fetchImpl(query, { headers });
      if (!reread.ok) throw new Error(`Metadata post-write read failed: ${await reread.text()}`);
      const found = await reread.json();
      if (found.length !== 1 || found[0].character_id !== asset.characterId ||
          found[0].author_id !== asset.authorId || found[0].asset_type !== "primary" ||
          found[0].sort_order !== 0) {
        throw new Error(`Metadata insert/verification failed: ${insertError || "expected one exact metadata row"}`);
      }
    },

    async updateSnapshotIfUnchanged({ sessionId, characterId, expectedSnapshot, nextSnapshot }) {
      const response = await fetchImpl(endpoint("rest/v1/rpc/poyozz_migrate_legacy_chat_snapshot"), {
        method: "POST",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({
          p_session_id: sessionId,
          p_character_id: characterId,
          p_expected_snapshot: expectedSnapshot,
          p_next_snapshot: nextSnapshot,
        }),
      });
      if (!response.ok) throw new Error(`Snapshot RPC failed (${response.status}): ${await response.text()}`);
      return response.json();
    },

    async clearCharacterAvatarIfUnchanged({ characterId, authorId, expectedImageSha256 }) {
      const response = await fetchImpl(endpoint("rest/v1/rpc/poyozz_clear_legacy_character_avatar"), {
        method: "POST",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({
          p_character_id: characterId,
          p_author_id: authorId,
          p_expected_data_uri_sha256: expectedImageSha256,
        }),
      });
      if (!response.ok) throw new Error(`Avatar clear RPC failed (${response.status}): ${await response.text()}`);
      return response.json();
    },
  };
}

export async function runLocalMigration({ url, serviceRoleKey, manifest, persist, fetchImpl }) {
  assertLocalSupabaseUrl(url);
  const adapter = createLocalSupabaseAdapter({ url, serviceRoleKey, fetchImpl });
  return applyLegacyImageMigration({ manifest, adapter, persist });
}
