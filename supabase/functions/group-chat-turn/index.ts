// Single-call group AI: one model reads every character card and selects speakers.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { findPrivateContextLeak, preparePrivateContext } from "../_shared/private-context-guard.ts";
import { collectDerivedPrivateProfileValues, formatCharacterAiProfilePrompt } from "../_shared/character-ai-profile-prompt.ts";
import { parseGroupTurnEnvelopeDetailed, serializeGroupPhoneUpdatesForRpc } from "../_shared/group-turn-envelope.ts";
import { buildGroupMemoryContext, getGroupHistoryLimit } from "../_shared/group-memory-context.ts";
import { requestOpenRouterChatCompletion, POYOZZ_DEFAULT_CHAT_MODEL } from "../_shared/openrouter-chat-completions.ts";
import { buildRoleplayResponseGuidelines } from "../_shared/roleplay-response-guidelines.ts";
import { processDueGroupMemorySummary } from "../_shared/story-memory-summary.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json" },
});
const asRow = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
const asText = (value: unknown): string => typeof value === "string" ? value.trim() : "";
const isUuid = (value: unknown): value is string =>
  typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const MODEL = POYOZZ_DEFAULT_CHAT_MODEL;
const TIMEOUT_MS = 55_000;
const CLEANUP_RESERVE_MS = 12_000;

type Speaker = { id: string; name: string; sceneId: string | null; sceneName: string; snapshot: Record<string, unknown>; phoneSettings: Record<string, unknown>; phoneNotifications: Array<{ title: string; body: string }> };

async function refund(admin: any, userId: string, turnId: string, code: string) {
  const { data, error } = await admin.rpc("refund_group_chat_turn", {
    p_user_id: userId, p_turn_id: turnId, p_failure_code: code,
  });
  if (error) return { confirmed: false, error: error.message };
  const result = Array.isArray(data) ? data[0] : data;
  return { confirmed: result?.status === "refunded", balance: result ? { silver_coins: result.balance_silver, diamonds: result.balance_diamonds } : null };
}


function extractGroupSuggestedReplies(output: string): string[] {
  let text = asText(output).trim();
  if (text.startsWith("```")) {
    const firstLine = text.indexOf("\n");
    const lastFence = text.lastIndexOf("```");
    if (firstLine >= 0 && lastFence > firstLine) text = text.slice(firstLine + 1, lastFence).trim();
  }
  try {
    const root = asRow(JSON.parse(text));
    const raw = Array.isArray(root.suggested_replies) ? root.suggested_replies : [];
    if (raw.length !== 3) return [];
    const replies = raw.map((item: unknown) => asText(item));
    return replies.every((reply: string) => Array.from(reply).length >= 30 && Array.from(reply).length <= 90 && reply.split("*").length >= 3) ? replies : [];
  } catch { return []; }
}
function scheduleGroupMemorySummary(admin: any, groupId: string, userId: string, apiKey: string) {
  const task = processDueGroupMemorySummary(admin, groupId, userId, apiKey).catch((error) => {
    console.error("Group memory summary background task failed:", error instanceof Error ? error.message : "unknown_error");
  });
  const edgeRuntime = (globalThis as typeof globalThis & {
    EdgeRuntime?: { waitUntil: (task: Promise<unknown>) => void };
  }).EdgeRuntime;
  if (edgeRuntime?.waitUntil) edgeRuntime.waitUntil(task);
  else void task;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const apiKey = Deno.env.get("OPENROUTER_API_KEY")?.trim();
  const authorization = request.headers.get("Authorization");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return json({ error: "server_not_configured" }, 503);
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);
  if (!apiKey) return json({ error: "openrouter_not_configured", retryAllowed: true }, 503);

  let body: Record<string, unknown>;
  try { body = asRow(await request.json()); } catch { return json({ error: "invalid_json" }, 400); }
  const groupId = body.groupId;
  const requestKey = body.requestKey;
  const content = asText(body.content);
  if (!isUuid(groupId) || !isUuid(requestKey) || !content || content.length > 2000) {
    return json({ error: "invalid_group_turn_request" }, 400);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser();
  const user = authData?.user;
  if (authError || !user) return json({ error: "unauthorized" }, 401);
  const { data: active, error: activeError } = await userClient.rpc("account_is_active");
  if (activeError || active !== true) return json({ error: "account_not_active" }, 403);

  // Initialize wallet using the caller's authenticated context; the reservation
  // RPC itself is service-role-only and checks group ownership again.
  const { error: walletError } = await userClient.rpc("ensure_wallet_account");
  if (walletError) return json({ error: "wallet_not_ready" }, 409);

  const { data: reservationRows, error: reserveError } = await admin.rpc("reserve_group_chat_turn", {
    p_user_id: user.id, p_group_id: groupId, p_request_key: requestKey, p_content: content,
  });
  if (reserveError) {
    const message = asText(reserveError.message);
    if (message.includes("group_insufficient_funds")) return json({ status: "insufficient_funds", error: "group_insufficient_funds" });
    if (message.includes("group_not_found_or_not_accessible")) return json({ error: "group_not_found_or_not_accessible" }, 403);
    if (message.includes("group_turn_in_progress")) return json({ status: "needs_reconciliation", error: "group_turn_in_progress", retryAllowed: false }, 409);
    return json({ error: "group_turn_reservation_failed" }, 503);
  }
  const reservation = Array.isArray(reservationRows) ? reservationRows[0] : reservationRows;
  if (!reservation?.turn_id) return json({ error: "group_reservation_state_missing" }, 503);
  const turnId = String(reservation.turn_id);
  if (reservation.turn_status === "completed" && reservation.charge_status === "settled") {
    scheduleGroupMemorySummary(admin, groupId, user.id, apiKey);
    const [{ data: saved, error: savedError }, { data: phoneRows, error: phoneError }, { data: suggestionRow }, { data: worldStateRow }] = await Promise.all([
      admin.from("chat_group_messages")
        .select("id,group_id,scene_id,turn_id,sequence_no,speaker_type,character_id,speaker_snapshot,content,created_at")
        .eq("group_id", groupId).eq("turn_id", turnId).is("deleted_at", null)
        .order("sequence_no", { ascending: true }),
      admin.from("chat_group_members").select("character_id,phone_notifications").eq("group_id", groupId),
      admin.from("chat_group_turns").select("suggested_replies").eq("id", turnId).eq("user_id", user.id).maybeSingle(),
      admin.from("chat_groups").select("story_time,story_location").eq("id", groupId).eq("owner_id", user.id).maybeSingle(),
    ]);
    if (savedError || phoneError) return json({ status: "needs_reconciliation", error: "completed_turn_read_failed", retryAllowed: false }, 503);
    return json({
      status: "completed", turnId, messages: saved || [], idempotent: true,
      suggested_replies: Array.isArray(suggestionRow?.suggested_replies) ? suggestionRow.suggested_replies : [],
      phone_updates: (phoneRows || []).map((row: any) => ({
        characterId: row.character_id,
        notifications: Array.isArray(row.phone_notifications) ? row.phone_notifications : [],
      })),
      story_world_state: {
        storyTime: asText(worldStateRow?.story_time),
        storyLocation: asText(worldStateRow?.story_location),
      },
    });
  }
  if (!reservation.is_new) {
    if (reservation.charge_status === "refunded" || reservation.turn_status === "failed") {
      const { data: priorTurn } = await admin.from("chat_group_turns")
        .select("failure_code").eq("id", turnId).eq("user_id", user.id).maybeSingle();
      if (priorTurn?.failure_code === "provider_timeout" ||
          priorTurn?.failure_code === "provider_timeout_watchdog") {
        return json({ status: "timed_out", error: "provider_timeout", retryAllowed: false }, 200);
      }
      return json({ status: "refunded", error: "turn_already_refunded", retryAllowed: false }, 409);
    }
    if (reservation.turn_status === "processing" && reservation.charge_status === "reserved") {
      // A retry after a lost Edge Function response can expire the original turn
      // immediately, without waiting for the next cron tick.
      const { data: expirationRows, error: expirationError } = await admin.rpc("expire_group_chat_turn", {
        p_user_id: user.id, p_turn_id: turnId,
      });
      const expiration = Array.isArray(expirationRows) ? expirationRows[0] : expirationRows;
      if (expirationError) {
        return json({ status: "needs_reconciliation", error: "turn_expiration_unavailable", retryAllowed: false }, 503);
      }
      if (expiration?.status === "refunded") {
        return json({ status: "timed_out", error: "provider_timeout", retryAllowed: false }, 200);
      }
      if (expiration?.status === "completed") {
        return json({ status: "needs_reconciliation", error: "turn_completed_reload_required", retryAllowed: false }, 409);
      }
    }
    return json({ status: "needs_reconciliation", error: "turn_already_processing", retryAllowed: false }, 409);
  }

  // The DB deadline starts at reservation. Reserve twelve seconds for provider
  // cancellation, the atomic refund RPC, and the response before the 55-second watchdog.
  const processingDeadlineAt = Date.now() + TIMEOUT_MS - CLEANUP_RESERVE_MS;

  const { data: group, error: groupError } = await admin.from("chat_groups")
    .select("id,owner_id,name,world_background,scene_mode,player_name,player_persona,world_character_id,story_time,story_location,deleted_at")
    .eq("id", groupId).eq("owner_id", user.id).is("archived_at", null).is("deleted_at", null).maybeSingle();
  if (groupError || !group) {
    const refunded = await refund(admin, user.id, turnId, "group_context_unavailable");
    return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: "group_context_unavailable", balance: refunded.balance, retryAllowed: false }, refunded.confirmed ? 200 : 503);
  }

  const useSharedGroupMemory = asText(group.scene_mode) === "shared";
  const [memberResult, sceneResult, playerResult, latestGroupMemoryResult, curatedGroupMemoryResult] = await Promise.all([
    admin.from("chat_group_members")
      .select("id,group_id,character_id,position,scene_id,character_snapshot,phone_notifications")
      .eq("group_id", groupId).order("position", { ascending: true }),
    admin.from("chat_group_scenes")
      .select("id,name,description,position").eq("group_id", groupId).order("position", { ascending: true }),
    admin.from("profiles").select("id,nickname,persona_presets").eq("id", user.id).maybeSingle(),
    useSharedGroupMemory
      ? admin.from("chat_group_memory_summaries")
        .select("batch_number,summary,important,user_edited,processed_at")
        .eq("group_id", groupId).eq("user_id", user.id).eq("status", "completed")
        .not("summary", "is", null)
        .order("batch_number", { ascending: false }).limit(1).maybeSingle()
      : Promise.resolve({ data: null, error: null }),
    useSharedGroupMemory
      ? admin.from("chat_group_memory_summaries")
        .select("batch_number,summary,important,user_edited,processed_at")
        .eq("group_id", groupId).eq("user_id", user.id).eq("status", "completed")
        .or("important.eq.true,user_edited.eq.true")
        .not("summary", "is", null)
        .order("batch_number", { ascending: false }).limit(8)
      : Promise.resolve({ data: [], error: null }),
  ]);
  const groupMemoryLookupFailed = Boolean(latestGroupMemoryResult.error || curatedGroupMemoryResult.error);
  if (groupMemoryLookupFailed) {
    console.warn("group_chat_turn_memory_summary_lookup_failed", {
      code: latestGroupMemoryResult.error?.code || curatedGroupMemoryResult.error?.code || "unknown",
    });
  }
  const latestGroupMemory = latestGroupMemoryResult.error ? null : asRow(latestGroupMemoryResult.data);
  const curatedGroupMemories = !curatedGroupMemoryResult.error && Array.isArray(curatedGroupMemoryResult.data)
    ? curatedGroupMemoryResult.data
    : [];
  const groupMemoryContext = buildGroupMemoryContext(
    asText(group.scene_mode),
    latestGroupMemory,
    curatedGroupMemories,
  );
  const groupHistoryLimit = getGroupHistoryLimit(
    asText(group.scene_mode),
    Boolean(asText(latestGroupMemory.summary)),
    groupMemoryLookupFailed,
  );
  if (memberResult.error || sceneResult.error || playerResult.error ||
      !Array.isArray(memberResult.data) || memberResult.data.length < 1 || memberResult.data.length > 3) {
    const refunded = await refund(admin, user.id, turnId, "group_context_lookup_failed");
    return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: "group_context_unavailable", balance: refunded.balance, retryAllowed: false }, refunded.confirmed ? 200 : 503);
  }

  const scenes = new Map((sceneResult.data || []).map((scene: any) => [scene.id, scene]));
  const members = memberResult.data as any[];
  const characterIds = members.map(m => m.character_id).filter(isUuid);
  const [historyResult, charactersResult, privateRowsResult] = await Promise.all([
    admin.from("chat_group_messages")
      .select("turn_id,scene_id,speaker_type,character_id,speaker_snapshot,content,created_at,sequence_no")
      .eq("group_id", groupId).is("deleted_at", null)
      .order("created_at", { ascending: false }).order("sequence_no", { ascending: false }).order("id", { ascending: false }).limit(groupHistoryLimit),
    characterIds.length ? admin.from("characters")
      .select("id,author_id,name,intro,style,gender,age,race,tags,phone_settings,deleted_at")
      .in("id", characterIds) : Promise.resolve({ data: [], error: null }),
    characterIds.length ? admin.from("character_private_info")
      .select("character_id,author_id,private_info,personality_profile")
      .in("character_id", characterIds) : Promise.resolve({ data: [], error: null }),
  ]);
  if (historyResult.error || charactersResult.error || privateRowsResult.error) {
    const refunded = await refund(admin, user.id, turnId, "character_context_lookup_failed");
    return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: "character_context_unavailable", balance: refunded.balance, retryAllowed: false }, refunded.confirmed ? 200 : 503);
  }

  const characters = new Map((charactersResult.data || []).map((row: any) => [row.id, row]));
  const privateRows = new Map((privateRowsResult.data || []).map((row: any) => [row.character_id, row]));
  const speakers: Speaker[] = [];
  const protectedContext: string[] = [];
  const profileSections: string[] = [];
  const profileContextStartedAt = Date.now();
  const derivedProfileRows = await Promise.all(members.map(async (member: any) => {
    const snapshot = asRow(member.character_snapshot);
    const characterId = asText(member.character_id) || asText(snapshot.id);
    const character = characters.get(characterId) || {};
    if (!isUuid(characterId) || !asText(character.author_id)) return [characterId, null] as const;
    const { data, error } = await admin.rpc("get_character_ai_profile_for_chat", {
      p_character_id: characterId, p_author_id: character.author_id,
    });
    return [characterId, !error && data ? data : null] as const;
  }));
  const derivedProfiles = new Map(derivedProfileRows);
  console.info("group_chat_turn_profile_context_ready", { elapsedMs: Date.now() - profileContextStartedAt, memberCount: derivedProfiles.size });

  for (const member of members) {
    const snapshot = asRow(member.character_snapshot);
    const characterId = asText(member.character_id) || asText(snapshot.id);
    const character = characters.get(characterId) || {};
    const privateInfo = privateRows.get(characterId) || {};
    const scene = scenes.get(member.scene_id) || {};
    const name = asText(snapshot.name) || asText(character.name) || "角色";
    if (!isUuid(characterId) || !name) continue;

    let derivedProfilePrompt = "";
    const derived = derivedProfiles.get(characterId);
    if (derived) {
      derivedProfilePrompt = formatCharacterAiProfilePrompt(derived);
      protectedContext.push(...collectDerivedPrivateProfileValues(derived));
    }
    const rawPrivate = preparePrivateContext(asText(privateInfo.private_info), privateInfo.personality_profile);
    protectedContext.push(...rawPrivate.protectedValues);
    const personality = asText(asRow(privateInfo.personality_profile).personality) ||
      asText(asRow(privateInfo.personality_profile).personality_summary);
    const phoneSettings = asRow(character.phone_settings ?? snapshot.phoneSettings ?? snapshot.phone_settings);
    const rawPhoneNotifications = Array.isArray(member.phone_notifications) ? member.phone_notifications : [];
    const phoneNotifications = rawPhoneNotifications.map((item: unknown) => {
      const notice = asRow(item);
      return { title: asText(notice.title), body: asText(notice.body) };
    }).filter((notice: { title: string; body: string }) => notice.title && notice.body).slice(0, 8);
    speakers.push({
      id: characterId, name, sceneId: isUuid(member.scene_id) ? member.scene_id : null,
      sceneName: asText(scene.name), snapshot, phoneSettings, phoneNotifications,
    });
    profileSections.push([
      "【角色卡 " + (speakers.length) + "｜" + name + "｜角色 ID " + characterId + "】",
      "身份與背景：" + [asText(character.gender || snapshot.gender), asText(character.age || snapshot.age), asText(character.race || snapshot.race)].filter(Boolean).join("／"),
      "角色介紹：" + (asText(character.intro) || asText(snapshot.intro)),
      "作者人格與性格設定：" + JSON.stringify(privateInfo.personality_profile || {}).slice(0, 5000),
      "性格摘要與演繹風格：" + [personality, asText(character.style || snapshot.style)].filter(Boolean).join("\n"),
      "標籤：" + JSON.stringify(character.tags || snapshot.tags || []),
      "開場情境：" + asText(snapshot.opening),
      "角色衍生扮演檔：\n" + derivedProfilePrompt,
      "所屬場景 ID：" + asText(member.scene_id) + "｜場景：" + asText(scene.name) + "｜" + asText(scene.description),
      "角色手機欄位設定：" + JSON.stringify(speakers.at(-1)?.phoneSettings || {}).slice(0, 1800),
      "角色目前手機通知狀態：" + JSON.stringify(speakers.at(-1)?.phoneNotifications || []).slice(0, 1800),
    ].join("\n"));
  }
  if (speakers.length !== members.length) {
    const refunded = await refund(admin, user.id, turnId, "group_speaker_snapshot_invalid");
    return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: "group_speaker_snapshot_invalid", balance: refunded.balance, retryAllowed: false }, refunded.confirmed ? 200 : 503);
  }

  const history = (historyResult.data || []).filter((row: any) => row.turn_id !== turnId).slice().reverse().map((row: any) => {
    const speaker = row.speaker_type === "user" ? "玩家" :
      row.speaker_type === "character" ? (asText(asRow(row.speaker_snapshot).name) || "角色") : "系統";
    const message = asText(row.content) === "__GROUP_CONTINUE__" ? "（玩家要求延續劇情）" : asText(row.content);
    return "[場景 " + (asText(row.scene_id) || "共同") + "] " + speaker + "：" + message;
  }).filter(Boolean).join("\n");
  const currentMessage = content === "__GROUP_CONTINUE__"
    ? "（玩家沒有輸入新文字，請自然延續目前場景，不要替玩家發言或決定行動。）"
    : content;
  const player = asRow(playerResult.data);
  const playerName = asText(player.nickname) || "玩家";
  const worldAnchor = speakers.find(speaker => speaker.id === asText(group.world_character_id));
  const initialOpeningContext = (sceneResult.data || []).map((scene: any) => {
    const name = asText(scene.name) || "未命名場景";
    const description = asText(scene.description);
    return description ? "【" + name + "】\n" + description : "";
  }).filter(Boolean).join("\n\n");
  const systemPrompt = [
    "你是 POYOZZ 群組互動故事中的唯一 AI 扮演者。你同時讀取所有角色卡，但必須嚴格區分每位角色的人格、記憶、說話方式與場景位置。",
    "【世界與玩家】群組名稱：" + asText(group.name) + "。共同世界觀：" + asText(group.world_background) + "。世界觀參照角色：" + (worldAnchor?.name || "未指定") + "。",
    "玩家稱呼：" + (asText(group.player_name) || playerName) + "。玩家人設：" + asText(group.player_persona) + "。玩家是劇情主導者；絕不可替玩家創作台詞、思想、感受、決定或未描述的行動。",
    "【角色卡】\n" + profileSections.join("\n\n").slice(0, 24000),
    "【群組場景模式】" + asText(group.scene_mode) + "。shared 代表角色處於同一共同場景；separate 代表每位角色只知道自己所屬場景。近期對話每行都有場景 ID；separate 模式下，角色只能依自己所屬場景的訊息回應，除非對話已合理建立資訊傳遞，否則不可引用其他場景的即時事件。",
    "【遊戲時間與地點】目前故事時間：" + (asText(group.story_time) || "尚未確認") + "；目前故事地點：" + (asText(group.story_location) || "尚未確認") + "。這是劇情內的世界狀態，不是現實時間或手機裝置時間；只能依故事事件推進，不可讀取、推測或使用系統現在時間。若尚未有足夠線索，保留空字串，不可用現實時間補值。",
    "【玩家設定的初始開場情境】\n" + (initialOpeningContext || "（玩家未提供初始開場情境）") + "。這是玩家建立群組時提供的原始開場內容，必須視為故事已成立的共同上下文；不得重新生成、改寫或摘要開場。AI 只在玩家送出第一則訊息後才回覆，並須同時依據這段開場與本輪玩家訊息自然承接劇情。",
    ...(groupMemoryContext ? [groupMemoryContext] : []),
    "【近期群組對話】\n" + history.slice(-14000),
    "【本輪玩家訊息】\n" + currentMessage,
    "【本輪角色選擇與發言規則】每輪由你自行判斷 1～3 名最適合回應的角色，不要求每個角色輪流發言，也不可為了湊人數讓所有人都說話。可以由一位角色回應，也可以讓角色之間自然互動。若玩家明確以 @角色名稱 指定對象，優先由該角色回應，但仍可在劇情確有必要時讓另一角色補充。未被選中的角色保持安靜，不要輸出空白發言。",
    "【角色卡遵循】每位角色只能以自己的角色卡、已知記憶、可觀察資訊和合理推論行動。不得混用人格、口吻或背景；不得擅自替另一角色決定內心或行為。角色可對玩家說話，也可彼此對話。分開場景的角色不得跨場景瞬間出現。",
    buildRoleplayResponseGuidelines("group"),
    "【群組建議回覆】每回合產生恰好三則繁體中文建議回覆，每則 30～80 字；每則都必須同時包含單星號旁白／動作（*...*）與玩家自然對白，旁白只能描述玩家此刻可以選擇採取的行動，不得替玩家捏造已發生的事或內心想法。三則回覆方向必須不同，依最新群組對話與角色互動生成，不可使用標題、數字、固定模板或操作說明。",
    "【輸出格式】只輸出一個 JSON object，不要 Markdown code fence 或額外說明。格式：{\"speeches\":[{\"speaker_id\":\"群組內角色 ID\",\"content\":\"角色完整發言\"}],\"phone_updates\":[{\"character_id\":\"群組內角色 ID\",\"notifications\":[{\"title\":\"手機欄位顯示名稱\",\"body\":\"最新狀態\"}]}],\"story_world_state\":{\"story_time\":\"YYYY-MM-DD HH:mm、故事內時段文字或空字串\",\"story_location\":\"故事內地點或空字串\"},\"suggested_replies\":[\"玩家可直接送出的完整回覆 1\",\"玩家可直接送出的完整回覆 2\",\"玩家可直接送出的完整回覆 3\"]}。story_world_state 只依故事內容維護；有既有值時，除非劇情明確改變，否則沿用；不可把現在日期、現實時間或裝置時間填入。有明確年月日時使用 YYYY-MM-DD HH:mm；若只有時段線索，使用「晚上 19:30」等故事內文字；完全未知才用空字串。speeches 必須輸出 1～3 段，speaker_id 只能使用上方角色卡提供的精確 UUID，絕不可輸出群組外人物作為發言者；NPC 可以在角色對白、手機通知內容中自然出現，但不得成為群組 AI 發言標籤。phone_updates 必須為群組內每一位角色各輸出且只輸出一筆，無論該角色本輪是否發言、手機內容是否有變化，都不可省略；character_id 必須使用該角色卡提供的精確 UUID。每位角色的 notifications 最多 8 筆；若角色手機欄位設定含 noticePrompts 或 notices，必須依設定順序逐欄輸出，數量必須完全一致，每個欄位一筆，不可漏欄、合併、多產生或輸出空陣列；title 使用設定文字「|」之前的顯示名稱，並將 {CHAR}/{USER} 替換成實際稱呼，body 嚴格遵守「|」之後的作者指示。即使角色本輪沒有發言，也要依該角色自己的角色卡、場景、可知資訊與最近手機狀態更新手機欄位。沒有變化時原樣延續最近狀態；首次尚無狀態時，依欄位語意填入明確且不捏造事實的內容，不能留空。若沒有設定欄位，才可依角色職業、人物關係、時間與目前劇情產生 0～8 筆合理通知。手機內容只記錄該角色自己的生活、訊息、工作與可知狀態，不可把玩家在聊天室說的話當成已傳送的簡訊；玩家只有明確描述拿起手機傳訊息／打電話時才可成為手機事件來源。未知資訊不得編造；沒有新資訊時沿用最近手機狀態，不得為了更新而改寫；若是第一次建立欄位且沒有可靠資訊，依欄位語意填寫「目前沒有足夠資訊」「目前沒有新的手機訊息」「目前沒有待辦事項」等明確狀態，不可輸出空白。每個通知 title 1～80 字、body 1～500 字，必須是可顯示給玩家的一行簡短內容。speeches 中角色動作與敘述使用單星號包覆，對白直接書寫；絕不可替玩家補寫台詞、思想、感受或行動。",
  ].join("\n\n");

  let provider;
  const providerStartedAt = Date.now();
  const providerTimeoutMs = processingDeadlineAt - Date.now();
  console.info("group_chat_turn_provider_start", { memberCount: speakers.length, promptChars: systemPrompt.length, providerTimeoutMs });
  if (providerTimeoutMs <= 0) {
    const refunded = await refund(admin, user.id, turnId, "provider_timeout");
    return json({
      status: refunded.confirmed ? "timed_out" : "needs_reconciliation",
      error: refunded.confirmed ? "provider_timeout" : "timeout_refund_unconfirmed",
      balance: refunded.balance,
      retryAllowed: false,
    }, refunded.confirmed ? 200 : 503);
  }
  try {
    provider = await requestOpenRouterChatCompletion({
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: currentMessage },
      ],
      apiKey,
      model: MODEL,
      timeoutMs: providerTimeoutMs,
    });
  } catch (error) {
    // The provider request has a firm 55-second deadline. If our own AbortController
    // fires, this turn did not produce a usable reply for the player: refund the
    // reserved in-app charge and report a timeout. Provider-side usage may still
    // have occurred, but it must never be passed on to the player for this turn.
    const errorName = String((error as { name?: unknown } | null)?.name || "");
    const errorCode = String((error as { code?: unknown } | null)?.code || "");
    console.warn("group_chat_turn_provider_failed", { elapsedMs: Date.now() - providerStartedAt, errorName, errorCode });
    if (errorName === "AbortError" || errorCode === "ABORT_ERR") {
      const refunded = await refund(admin, user.id, turnId, "provider_timeout");
      return json({
        status: refunded.confirmed ? "timed_out" : "needs_reconciliation",
        error: refunded.confirmed ? "provider_timeout" : "timeout_refund_unconfirmed",
        balance: refunded.balance,
        retryAllowed: false,
      }, refunded.confirmed ? 200 : 503);
    }
    // A non-timeout network disconnect has no reliable signal that the provider
    // request was cancelled; leave it unresolved for reconciliation.
    return json({ status: "needs_reconciliation", error: "provider_outcome_unknown", retryAllowed: false }, 503);
  }

  console.info("group_chat_turn_provider_finished", { elapsedMs: Date.now() - providerStartedAt, resultKind: provider.result.kind, httpStatus: provider.httpStatus });
  const safeRequestId = /^[A-Za-z0-9._:-]{1,128}$/.test(provider.requestId) ? provider.requestId : null;
  await admin.from("chat_group_ai_usage").upsert({
    group_id: groupId,
    group_turn_id: turnId,
    user_id: user.id,
    requested_model: MODEL,
    returned_model: provider.model,
    upstream_provider: provider.provider || null,
    gateway_request_id: safeRequestId,
    prompt_tokens: Number(provider.usage.prompt_tokens) || null,
    completion_tokens: Number(provider.usage.completion_tokens) || null,
    total_tokens: Number(provider.usage.total_tokens) || null,
    cost_usd: Number(provider.usage.cost) || null,
    status: provider.result.kind === "generated" ? "completed" : "failed",
  }, { onConflict: "group_turn_id" });

  if (provider.result.kind === "content_rejected") {
    const refunded = await refund(admin, user.id, turnId, "provider_content_rejected");
    return json({ status: refunded.confirmed ? "content_rejected" : "needs_reconciliation", balance: refunded.balance, retryAllowed: false }, refunded.confirmed ? 200 : 503);
  }
  if (provider.result.kind !== "generated") {
    const confirmedClientRejection = provider.result.kind === "empty_output" ||
      (provider.result.kind === "provider_error" &&
       provider.httpStatus >= 400 && provider.httpStatus < 500 && provider.httpStatus !== 408 && provider.httpStatus !== 409);
    if (confirmedClientRejection) {
      const refunded = await refund(admin, user.id, turnId, "provider_request_rejected");
      return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: provider.result.kind === "provider_error" ? provider.result.code : "provider_error", balance: refunded.balance, retryAllowed: false }, refunded.confirmed ? 200 : 503);
    }
    return json({ status: "needs_reconciliation", error: provider.result.kind === "provider_error" ? provider.result.code : "empty_output", retryAllowed: false }, 503);
  }

  if (findPrivateContextLeak(provider.result.text, protectedContext, [])) {
    const refunded = await refund(admin, user.id, turnId, "private_context_output_blocked");
    return json({ status: refunded.confirmed ? "content_rejected" : "needs_reconciliation", error: "private_context_output_blocked", balance: refunded.balance, retryAllowed: false }, refunded.confirmed ? 200 : 503);
  }

  const envelopeResult = parseGroupTurnEnvelopeDetailed(provider.result.text, speakers, asText(group.player_name) || playerName);
  const parsed = envelopeResult.envelope;
  const suggestedReplies = extractGroupSuggestedReplies(provider.result.text);
  if (!parsed) {
    console.warn("group_chat_turn_envelope_rejected", {
      reason: envelopeResult.errorCode || "unknown",
      outputChars: provider.result.text.length,
    });
    const refunded = await refund(admin, user.id, turnId, "invalid_group_turn_envelope");
    return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: "invalid_group_turn_envelope", failureReason: envelopeResult.errorCode || "unknown", balance: refunded.balance, retryAllowed: false }, refunded.confirmed ? 200 : 503);
  }
  if (envelopeResult.warningCount > 0) {
    console.info("group_chat_turn_metadata_warnings", { warningCount: envelopeResult.warningCount });
  }

  const speeches = parsed.speeches.map(item => ({ speaker_id: item.speakerId, content: item.content }));
  const phoneUpdatesForRpc = serializeGroupPhoneUpdatesForRpc(parsed.phoneUpdates);
  const { data: completed, error: completeError } = await admin.rpc("complete_group_chat_turn", {
    p_user_id: user.id, p_turn_id: turnId, p_speeches: speeches, p_phone_updates: phoneUpdatesForRpc,
  });
  if (completeError || completed !== "completed") {
    // A completion RPC that acquires the transaction locks after the deadline
    // must lose to the timeout policy, even if the provider returned content.
    if (asText(completeError?.message).includes("group_turn_deadline_exceeded")) {
      const refunded = await refund(admin, user.id, turnId, "provider_timeout");
      return json({
        status: refunded.confirmed ? "timed_out" : "needs_reconciliation",
        error: refunded.confirmed ? "provider_timeout" : "timeout_refund_unconfirmed",
        balance: refunded.balance,
        retryAllowed: false,
      }, refunded.confirmed ? 200 : 503);
    }
    // If persistence definitely did not settle, refund atomically. If the
    // completion committed but its acknowledgement was lost, the refund RPC
    // refuses to reverse a settled charge and the turn remains reconcilable.
    const refunded = await refund(admin, user.id, turnId, "group_reply_persistence_failed");
    if (refunded.confirmed) {
      const { data: persistedTurn } = await admin.from("chat_group_turns")
        .select("failure_code").eq("id", turnId).eq("user_id", user.id).maybeSingle();
      if (persistedTurn?.failure_code === "provider_timeout" ||
          persistedTurn?.failure_code === "provider_timeout_watchdog") {
        return json({ status: "timed_out", error: "provider_timeout", balance: refunded.balance, retryAllowed: false });
      }
      return json({ status: "refunded", error: "group_reply_persistence_failed", balance: refunded.balance, retryAllowed: false });
    }
    return json({ status: "needs_reconciliation", error: "group_reply_persistence_unknown", retryAllowed: false }, 503);
  }

  let nextStoryWorldState = {
    storyTime: parsed.storyWorldState?.storyTime || asText(group.story_time),
    storyLocation: parsed.storyWorldState?.storyLocation || asText(group.story_location),
  };
  if (parsed.storyWorldState && (nextStoryWorldState.storyTime || nextStoryWorldState.storyLocation)) {
    const { error: worldStateSaveError } = await admin.from("chat_groups")
      .update({
        story_time: nextStoryWorldState.storyTime || null,
        story_location: nextStoryWorldState.storyLocation || null,
      })
      .eq("id", groupId).eq("owner_id", user.id);
    if (worldStateSaveError) {
      console.warn("group_chat_turn_world_state_persist_failed", { code: worldStateSaveError.code || "unknown" });
      nextStoryWorldState = {
        storyTime: asText(group.story_time),
        storyLocation: asText(group.story_location),
      };
    }
  }

  const { error: suggestionSaveError } = await admin.from("chat_group_turns")
    .update({ suggested_replies: suggestedReplies })
    .eq("id", turnId).eq("user_id", user.id);
  if (suggestionSaveError) console.warn("group_chat_turn_suggestions_persist_failed", { code: suggestionSaveError.code || "unknown" });

  const { data: saved, error: savedError } = await admin.from("chat_group_messages")
    .select("id,group_id,scene_id,turn_id,sequence_no,speaker_type,character_id,speaker_snapshot,content,created_at")
    .eq("group_id", groupId).eq("turn_id", turnId).is("deleted_at", null)
    .order("sequence_no", { ascending: true });
  if (savedError || !saved?.length) return json({ status: "needs_reconciliation", error: "completed_turn_read_failed", retryAllowed: false }, 503);
  scheduleGroupMemorySummary(admin, groupId, user.id, apiKey);

  return json({
    status: "completed",
    turnId,
    messages: saved,
    suggested_replies: suggestedReplies,
    phone_updates: parsed.phoneUpdates,
    story_world_state: nextStoryWorldState,
    billing: { cost: reservation.cost, silver_charged: reservation.silver_charged, diamonds_charged: reservation.diamonds_charged },
    provider: {
      gateway: "openrouter", model: provider.model, upstream: provider.provider || null,
      usage: {
        prompt_tokens: Number(provider.usage.prompt_tokens) || null,
        completion_tokens: Number(provider.usage.completion_tokens) || null,
        total_tokens: Number(provider.usage.total_tokens) || null,
        cost_usd: Number(provider.usage.cost) || null,
      },
    },
  });
});
