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

  // Resolve the character's active schedule on the server using Taiwan local time.
  // The client can request a location, but cannot supply or override schedule data.
  const { data: schedules, error: scheduleError } = await admin
    .from("character_schedules")
    .select("id,weekday,day_type,start_time,end_time,location_key,activity,priority,is_active")
    .eq("character_id", characterId)
    .eq("is_active", true)
    .eq("location_key", locationKey);
  if (scheduleError) return json({ error: "encounter_schedule_lookup_failed" }, 503);
  const now = new Date();
  const taiwanParts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Taipei", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(now);
  const part = (type: string) => taiwanParts.find(item => item.type === type)?.value || "";
  const localDate = `${part("year")}-${part("month")}-${part("day")}`;
  const localMinute = Number(part("hour")) * 60 + Number(part("minute"));
  const dateAtOffset = (date: string, offset: number) => {
    const value = new Date(`${date}T12:00:00+08:00`);
    value.setUTCDate(value.getUTCDate() + offset);
    return value.toISOString().slice(0, 10);
  };
  const weekdayFor = (date: string) => new Date(`${date}T12:00:00+08:00`).getUTCDay();
  const minutes = (time: string) => {
    const match = /^(\\d{2}):(\\d{2})(?::\\d{2})?$/.exec(time);
    return match ? Number(match[1]) * 60 + Number(match[2]) : NaN;
  };
  const matches: Array<{ row: Record<string, unknown>; startDate: string; endDate: string; start: number; end: number }> = [];
  for (const row of (schedules || []) as Array<Record<string, unknown>>) {
    const start = minutes(String(row.start_time || ""));
    const end = minutes(String(row.end_time || ""));
    if (!Number.isFinite(start) || !Number.isFinite(end) || start === end) continue;
    for (const dayOffset of [-1, 0]) {
      const scheduleDate = dateAtOffset(localDate, dayOffset);
      const scheduleWeekday = weekdayFor(scheduleDate);
      if (row.weekday !== null && row.weekday !== undefined && Number(row.weekday) !== scheduleWeekday) continue;
      const weekend = scheduleWeekday === 0 || scheduleWeekday === 6;
      if (row.day_type === "weekday" && weekend) continue;
      if (row.day_type === "weekend" && !weekend) continue;
      if (row.day_type !== "any" && row.day_type !== "weekday" && row.day_type !== "weekend") continue;
      const overnight = end < start;
      const startDate = scheduleDate;
      const endDate = overnight ? dateAtOffset(scheduleDate, 1) : scheduleDate;
      const inWindow = dayOffset === -1
        ? overnight && localMinute < end
        : (overnight ? localMinute >= start : localMinute >= start && localMinute < end);
      if (!inWindow) continue;
      matches.push({ row, startDate, endDate, start, end });
    }
  }
  matches.sort((a, b) =>
    Number(b.row.priority || 0) - Number(a.row.priority || 0) ||
    Number(b.row.weekday !== null && b.row.weekday !== undefined) -
      Number(a.row.weekday !== null && a.row.weekday !== undefined) ||
    String(a.row.id).localeCompare(String(b.row.id))
  );
  const selected = matches[0];
  if (!selected) return json({ error: "character_not_at_this_location_now" }, 409);
  const timeText = (value: number) => `${String(Math.floor(value / 60)).padStart(2, "0")}:${String(value % 60).padStart(2, "0")}:00`;
  const scheduledStartAt = new Date(`${selected.startDate}T${timeText(selected.start)}+08:00`).toISOString();
  const scheduledEndAt = new Date(`${selected.endDate}T${timeText(selected.end)}+08:00`).toISOString();
  const scheduleSnapshot = {
    schedule_id: selected.row.id,
    weekday: selected.row.weekday,
    day_type: selected.row.day_type,
    start_time: selected.row.start_time,
    end_time: selected.row.end_time,
    location_key: locationKey,
    activity: selected.row.activity,
    priority: selected.row.priority,
    timezone: "Asia/Taipei",
    verified_at: now.toISOString(),
  };

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
