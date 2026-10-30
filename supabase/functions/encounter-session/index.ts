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
  if (!isUuid(characterId) || !isUuid(sessionId)) {
    return json({ error: "invalid_identifiers" }, 400);
  }

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

  // This check runs with the caller's JWT so private.current_user_is_adult()
  // evaluates the actual caller, not the service-role backend.
  const { data: canOpen, error: accessError } = await userClient.rpc(
    "can_open_encounter_session",
    { p_character_id: characterId },
  );
  if (accessError) return json({ error: "encounter_access_check_failed" }, 503);
  if (canOpen !== true) return json({ error: "character_unavailable_for_encounter" }, 403);

  // Retry-safe: return the same session only if it already belongs to this user,
  // is Encounter mode, and targets the same character. Never adopt an ID collision.
  const { data: existing, error: existingError } = await admin
    .from("chat_sessions")
    .select("id,user_id,character_id,character_name,character_snapshot,session_data,chat_mode,deleted_at")
    .eq("id", sessionId)
    .maybeSingle();
  if (existingError) return json({ error: "session_lookup_failed" }, 503);
  if (existing) {
    if (
      existing.user_id !== user.id ||
      existing.character_id !== characterId ||
      existing.chat_mode !== "encounter" ||
      existing.deleted_at !== null
    ) return json({ error: "session_id_conflict" }, 409);
    return json({ session: existing, idempotent: true });
  }

  const { data: character, error: characterError } = await admin
    .from("characters")
    .select("id,author_id,name,title,gender,age,avatar_url,intro,race,style,tags,phone_settings,visibility,first_published_at,deleted_at,is_nsfw")
    .eq("id", characterId)
    .eq("visibility", "public")
    .eq("review_status", "approved")
    .eq("rights_confirmed", true)
    .is("deleted_at", null)
    .maybeSingle();
  if (characterError) return json({ error: "character_lookup_failed" }, 503);
  if (!character) return json({ error: "character_unavailable_for_encounter" }, 403);

  // All snapshot identity fields are built from the database, never the request body.
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

  const { data: session, error: insertError } = await admin
    .from("chat_sessions")
    .insert({
      id: sessionId,
      user_id: user.id,
      character_id: character.id,
      character_name: character.name,
      status: "active",
      character_snapshot: snapshot,
      session_data: { encounter: { affinity: 0, relationshipStage: "first_meeting" } },
      chat_mode: "encounter",
    })
    .select("id,user_id,character_id,character_name,character_snapshot,session_data,chat_mode,created_at,updated_at")
    .single();

  if (insertError) {
    // A concurrent retry may have inserted the same session after our first read.
    const { data: retrySession } = await admin
      .from("chat_sessions")
      .select("id,user_id,character_id,character_name,character_snapshot,session_data,chat_mode,deleted_at")
      .eq("id", sessionId)
      .maybeSingle();
    if (
      retrySession?.user_id === user.id &&
      retrySession?.character_id === characterId &&
      retrySession?.chat_mode === "encounter" &&
      retrySession?.deleted_at === null
    ) return json({ session: retrySession, idempotent: true });
    return json({ error: "encounter_session_create_failed" }, 503);
  }

  return json({ session, idempotent: false }, 201);
});
