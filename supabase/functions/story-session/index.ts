import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });

const isUuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

const stages = new Set([
  "hostile", "dislike", "wary", "first_meeting",
  "acquaintance", "close", "intimate", "special",
]);

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = request.headers.get("Authorization");
  if (!url || !anonKey || !serviceRoleKey) return json({ error: "server_not_configured" }, 503);
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const characterId = body.characterId;
  const sessionId = body.sessionId;
  const originMode = body.originMode;
  const sourceEncounterSessionId = body.sourceEncounterSessionId ?? null;
  if (
    !isUuid(characterId) ||
    !isUuid(sessionId) ||
    !["fresh_story", "encounter_snapshot"].includes(String(originMode)) ||
    (originMode === "encounter_snapshot" && !isUuid(sourceEncounterSessionId)) ||
    (originMode === "fresh_story" && sourceEncounterSessionId !== null)
  ) return json({ error: "invalid_story_session_request" }, 400);

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  const user = authData?.user;
  if (authError || !user) return json({ error: "unauthorized" }, 401);

  const { data: active, error: activeError } = await userClient.rpc("account_is_active");
  if (activeError || active !== true) return json({ error: "account_not_active" }, 403);

  // A retry may only retrieve the exact Story session created for this owner/character.
  const { data: existing, error: existingError } = await admin
    .from("chat_sessions")
    .select("id,user_id,character_id,character_name,character_snapshot,chat_mode,deleted_at")
    .eq("id", sessionId)
    .maybeSingle();
  if (existingError) return json({ error: "session_lookup_failed" }, 503);
  if (existing) {
    if (
      existing.user_id !== user.id ||
      existing.character_id !== characterId ||
      existing.chat_mode !== "story" ||
      existing.deleted_at !== null
    ) return json({ error: "session_id_conflict" }, 409);
    const { data: relationship, error: relationshipError } = await admin
      .from("story_relationship_states")
      .select("session_id")
      .eq("session_id", sessionId)
      .eq("user_id", user.id)
      .maybeSingle();
    if (relationshipError) return json({ error: "relationship_state_lookup_failed" }, 503);
    if (!relationship) return json({ error: "story_session_incomplete" }, 409);
    const { data: relationshipState, error: stateError } = await admin
      .from("story_relationship_states")
      .select("affinity,relationship_stage,origin_mode,source_encounter_session_id,imported_memories,updated_at")
      .eq("session_id", sessionId)
      .eq("user_id", user.id)
      .maybeSingle();
    if (stateError || !relationshipState) return json({ error: "relationship_state_lookup_failed" }, 503);
    return json({ session: existing, relationship: relationshipState, idempotent: true });
  }

  // Run the existing role-access check under the caller JWT, not service_role.
  const { data: canStart, error: accessError } = await userClient.rpc(
    "character_can_start_chat",
    { p_character_id: characterId },
  );
  if (accessError) return json({ error: "character_access_check_failed" }, 503);
  if (canStart !== true) return json({ error: "character_unavailable_for_story" }, 403);

  const { data: character, error: characterError } = await admin
    .from("characters")
    .select("id,author_id,name,title,gender,age,avatar_url,intro,race,style,tags,phone_settings,visibility,first_published_at,deleted_at,is_nsfw")
    .eq("id", characterId)
    .is("deleted_at", null)
    .maybeSingle();
  if (characterError) return json({ error: "character_lookup_failed" }, 503);
  if (!character) return json({ error: "character_unavailable_for_story" }, 403);

  const snapshot = {
    id: character.id,
    name: character.name,
    title: character.title || "",
    gender: character.gender || "ambiguous",
    age: character.age ?? "",
    image: character.avatar_url || "",
    intro: character.intro || "",
    opening: "",
    race: character.race || "",
    style: character.style || "",
    phoneSettings: character.phone_settings || {},
    tags: Array.isArray(character.tags) ? character.tags : [],
    authorId: character.author_id,
    visibility: character.visibility,
    firstPublishedAt: character.first_published_at,
    deletedAt: character.deleted_at,
  };

  let affinity = 0;
  let relationshipStage = "first_meeting";
  let importedMemories: unknown[] = [];
  if (originMode === "encounter_snapshot") {
    // Only a server-settled lifecycle result is eligible for carry-over.
    const { data: source, error: sourceError } = await admin
      .from("encounter_session_lifecycle")
      .select("session_id,user_id,character_id,status,settlement_result,settled_at")
      .eq("session_id", sourceEncounterSessionId)
      .maybeSingle();
    if (sourceError) return json({ error: "encounter_snapshot_lookup_failed" }, 503);
    if (
      !source ||
      source.user_id !== user.id ||
      source.character_id !== characterId ||
      source.status !== "settled" ||
      !source.settled_at
    ) return json({ error: "encounter_not_settled" }, 409);

    const result = source.settlement_result && typeof source.settlement_result === "object"
      ? source.settlement_result as Record<string, unknown>
      : {};
    const finalAffinity = result.final_affinity;
    const finalStage = result.relationship_stage;
    const memories = result.memories;
    if (
      !Number.isInteger(finalAffinity) ||
      Number(finalAffinity) < -100 ||
      Number(finalAffinity) > 100 ||
      typeof finalStage !== "string" ||
      !stages.has(finalStage) ||
      (memories !== undefined && !Array.isArray(memories))
    ) return json({ error: "encounter_settlement_result_incomplete" }, 409);
    affinity = Number(finalAffinity);
    relationshipStage = finalStage;
    importedMemories = Array.isArray(memories) ? memories : [];
    if (JSON.stringify(importedMemories).length > 20000) {
      return json({ error: "encounter_memories_too_large" }, 409);
    }
  }

  const { data: session, error: createError } = await admin.rpc(
    "create_story_session_with_relationship",
    {
      p_session_id: sessionId,
      p_user_id: user.id,
      p_character_id: character.id,
      p_character_name: character.name,
      p_character_snapshot: snapshot,
      p_origin_mode: originMode,
      p_source_encounter_session_id: sourceEncounterSessionId,
      p_affinity: affinity,
      p_relationship_stage: relationshipStage,
      p_imported_memories: importedMemories,
    },
  );
  if (createError || !session?.id || session.id !== sessionId) {
    console.error("Story session creation failed:", createError?.message || "invalid_rpc_result");
    return json({ error: "story_session_create_failed" }, 503);
  }

  const { data: relationshipState, error: stateError } = await admin
    .from("story_relationship_states")
    .select("affinity,relationship_stage,origin_mode,source_encounter_session_id,imported_memories,updated_at")
    .eq("session_id", sessionId)
    .eq("user_id", user.id)
    .maybeSingle();
  if (stateError || !relationshipState) return json({ error: "relationship_state_lookup_failed" }, 503);

  return json({ session, relationship: relationshipState, idempotent: false }, 201);
});
