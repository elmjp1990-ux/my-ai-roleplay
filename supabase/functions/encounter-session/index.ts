import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import { resolveEncounterScheduleAvailability } from "../_shared/encounter-schedule-generation.ts";

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
  const locationKey = body.locationKey;
  if (!isUuid(characterId) || !isUuid(sessionId) ||
      typeof locationKey !== "string" || !/^[a-zA-Z0-9_-]{1,80}$/.test(locationKey)) {
    return json({ error: "invalid_identifiers_or_location" }, 400);
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

  // Retry-safe: return the same session only if it already belongs to this user,
  // is Encounter mode, and targets the same character. Never adopt an ID collision.
  const { data: existing, error: existingError } = await admin
    .from("chat_sessions")
    .select("id,user_id,character_id,character_name,character_snapshot,session_data,chat_mode,deleted_at,updated_at")
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
    const { data: lifecycle, error: lifecycleError } = await admin
      .from("encounter_session_lifecycle")
      .select("location_key")
      .eq("session_id", sessionId)
      .maybeSingle();
    if (lifecycleError) return json({ error: "encounter_lifecycle_lookup_failed" }, 503);
    if (!lifecycle || lifecycle.location_key !== locationKey) {
      return json({ error: "encounter_session_incomplete_or_location_conflict" }, 409);
    }
    return json({ session: existing, idempotent: true });
  }

  // New sessions must pass current character eligibility. Existing-session
  // idempotent recovery is checked first below so a character archived after
  // session creation cannot break a retry for that same owner's session.
  // This check runs with the caller's JWT so private.current_user_is_adult()
  // evaluates the actual caller, not the service-role backend.
  const { data: canOpen, error: accessError } = await userClient.rpc(
    "can_open_encounter_session",
    { p_character_id: characterId },
  );
  if (accessError) return json({ error: "encounter_access_check_failed" }, 503);
  if (canOpen !== true) return json({ error: "character_unavailable_for_encounter" }, 403);

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

  // Prefer a stable private Storage path over embedding image bytes in every chat snapshot.
  const { data: primaryIllustration, error: illustrationError } = await admin
    .from("character_illustrations")
    .select("storage_path")
    .eq("character_id", character.id)
    .eq("asset_type", "primary")
    .maybeSingle();
  if (illustrationError) return json({ error: "character_illustration_lookup_failed" }, 503);

  const { data: availableIllustrations } = await admin
    .from("character_illustrations")
    .select("id,display_name,asset_type,sort_order")
    .eq("character_id", character.id)
    .eq("asset_type", "gallery")
    .order("sort_order", { ascending: true })
    .limit(5);

  const [{ data: locationBackgrounds }, { data: defaultBackgrounds }] = await Promise.all([
    admin.from("encounter_scene_backgrounds")
      .select("id,location_key,display_name,asset_path,sort_order")
      .eq("location_key", locationKey)
      .eq("is_active", true)
      .order("sort_order", { ascending: true })
      .limit(5),
    admin.from("encounter_scene_backgrounds")
      .select("id,location_key,display_name,asset_path,sort_order")
      .eq("location_key", "*")
      .eq("is_active", true)
      .order("sort_order", { ascending: true })
      .limit(5),
  ]);
  const availableSceneBackgrounds = [
    ...(locationBackgrounds || []),
    ...(defaultBackgrounds || []),
  ].filter((row, index, rows) => rows.findIndex((item) => item.id === row.id) === index).slice(0, 5)
    .map((row) => ({
      id: row.id,
      locationKey: row.location_key,
      displayName: row.display_name,
      assetPath: row.asset_path,
    }));
  const illustrationChoices = (availableIllustrations || []).map((row) => ({
    id: row.id,
    displayName: row.display_name || "角色立繪",
    assetType: row.asset_type,
    sortOrder: row.sort_order,
  }));
  const defaultVisuals = {
    illustrationId: illustrationChoices[0]?.id || null,
    sceneBackgroundId: availableSceneBackgrounds[0]?.id || null,
    sceneBackgroundPath: availableSceneBackgrounds[0]?.assetPath || "./encounter-default-scene.webp",
  };

  // All snapshot identity fields are built from the database, never the request body.
  const snapshot: Record<string, unknown> = {
    id: character.id,
    name: character.name,
    title: character.title || "",
    gender: character.gender || "ambiguous",
    age: character.age ?? "",
    image: primaryIllustration?.storage_path ? "" : (character.avatar_url || ""),
    imagePath: primaryIllustration?.storage_path || "",
    intro: character.intro || "",
    race: character.race || "",
    style: character.style || "",
    phoneSettings: character.phone_settings || {},
    tags: Array.isArray(character.tags) ? character.tags : [],
    authorId: character.author_id,
    visibility: character.visibility,
    firstPublishedAt: character.first_published_at,
    deletedAt: character.deleted_at,
    availableIllustrations: illustrationChoices,
    availableSceneBackgrounds,
    defaultVisuals,
  };

  // Use the same database resolver as the public city map. It selects the
  // date-specific variant and validates the character's current location once.
  const { data: resolvedSchedule, error: scheduleError } = await admin.rpc(
    "resolve_encounter_character_schedule_with_scene",
    {
      p_character_id: characterId,
      p_user_id: user.id,
      p_location_key: locationKey,
      p_at: new Date().toISOString(),
    },
  );
  if (scheduleError) return json({ error: "encounter_schedule_lookup_failed" }, 503);
  const scheduleRow = Array.isArray(resolvedSchedule) ? resolvedSchedule[0] : resolvedSchedule;
  if (!scheduleRow?.schedule_id) return json({ error: "character_not_at_this_location_now" }, 409);

  if (resolveEncounterScheduleAvailability(scheduleRow.activity, scheduleRow.scene_description) === "sleeping") {
    return json({ error: "character_sleeping_unavailable_for_encounter" }, 409);
  }

  const scheduleSnapshot = {
    id: scheduleRow.schedule_id,
    weekday: scheduleRow.weekday,
    day_type: scheduleRow.day_type,
    start_time: scheduleRow.start_time,
    end_time: scheduleRow.end_time,
    location_key: scheduleRow.location_key,
    activity: scheduleRow.activity,
    priority: scheduleRow.priority,
    source_type: scheduleRow.source_type,
    variant_key: scheduleRow.variant_key,
    variant_weight: scheduleRow.variant_weight,
    is_outdoor: scheduleRow.is_outdoor === true,
    rain_fallback_location_key: scheduleRow.rain_fallback_location_key || null,
    rain_fallback_activity: scheduleRow.rain_fallback_activity || null,
    scheduled_start_at: scheduleRow.scheduled_start_at,
    scheduled_end_at: scheduleRow.scheduled_end_at,
  };
  const scheduledStartAt = scheduleRow.scheduled_start_at;
  const scheduledEndAt = scheduleRow.scheduled_end_at;
  // Freeze the validated location/activity context into the character snapshot so
  // Encounter turns do not need a second lifecycle-table read.
  snapshot.encounterSchedule = scheduleSnapshot;

  const { data: session, error: insertError } = await admin.rpc(
    "create_encounter_session_with_lifecycle",
    {
      p_session_id: sessionId,
      p_user_id: user.id,
      p_character_id: character.id,
      p_character_name: character.name,
      p_character_snapshot: snapshot,
      p_schedule_snapshot: scheduleSnapshot,
      p_location_key: locationKey,
      p_scheduled_start_at: scheduledStartAt,
      p_scheduled_end_at: scheduledEndAt,
    },
  );
  if (insertError || !session?.id || session.id !== sessionId) {
    console.error("Encounter session creation failed:", insertError?.message || "invalid_rpc_result");
    return json({ error: "encounter_session_create_failed" }, 503);
  }

  return json({ session, idempotent: false }, 201);
});
