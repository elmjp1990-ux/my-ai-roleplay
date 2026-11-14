// Single-call group AI: one model reads every character card and selects speakers.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { normalizeAiProviderResult } from "../_shared/ai-provider-result.ts";
import { findPrivateContextLeak, preparePrivateContext } from "../_shared/private-context-guard.ts";
import { collectDerivedPrivateProfileValues, formatCharacterAiProfilePrompt } from "../_shared/character-ai-profile-prompt.ts";
import { parseGroupSpeakerOutput } from "../_shared/group-speaker-output.ts";

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
const MODEL = "deepseek/deepseek-v4-flash-20260423";
const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const TIMEOUT_MS = 55_000;

type Speaker = { id: string; name: string; sceneId: string | null; sceneName: string; snapshot: Record<string, unknown> };

async function requestGeneration(messages: Array<{role: string; content: string}>, apiKey: string) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(OPENROUTER_URL, {
      method: "POST",
      headers: { Authorization: "Bearer " + apiKey, "Content-Type": "application/json", "X-OpenRouter-Title": "POYOZZ" },
      body: JSON.stringify({
        model: MODEL,
        messages,
        temperature: 0.85,
        provider: { only: ["deepinfra"], allow_fallbacks: false, data_collection: "deny" },
      }),
      signal: controller.signal,
    });
    let payload = asRow(await response.json().catch(() => ({ error: { code: "invalid_provider_response" } })));
    payload.status = response.status;
    if (!response.ok && payload.error == null) payload.error = { code: "http_" + response.status };
    return { result: normalizeAiProviderResult(payload), status: response.status, usage: asRow(payload.usage), provider: asText(payload.provider), model: asText(payload.model) || MODEL, requestId: response.headers.get("x-request-id") || asText(payload.id) };
  } finally {
    clearTimeout(timeout);
  }
}

async function refund(admin: any, userId: string, turnId: string, code: string) {
  const { data, error } = await admin.rpc("refund_group_chat_turn", {
    p_user_id: userId, p_turn_id: turnId, p_failure_code: code,
  });
  if (error) return { confirmed: false, error: error.message };
  const result = Array.isArray(data) ? data[0] : data;
  return { confirmed: result?.status === "refunded", balance: result ? { silver_coins: result.balance_silver, diamonds: result.balance_diamonds } : null };
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
    if (message.includes("group_insufficient_funds")) return json({ status: "insufficient_funds", error: "group_insufficient_funds" }, 402);
    if (message.includes("group_not_found_or_not_accessible")) return json({ error: "group_not_found_or_not_accessible" }, 403);
    return json({ error: "group_turn_reservation_failed" }, 503);
  }
  const reservation = Array.isArray(reservationRows) ? reservationRows[0] : reservationRows;
  if (!reservation?.turn_id) return json({ error: "group_reservation_state_missing" }, 503);
  const turnId = String(reservation.turn_id);
  if (reservation.turn_status === "completed" && reservation.charge_status === "settled") {
    const { data: saved, error: savedError } = await admin.from("chat_group_messages")
      .select("id,group_id,scene_id,turn_id,sequence_no,speaker_type,character_id,speaker_snapshot,content,created_at")
      .eq("group_id", groupId).eq("turn_id", turnId).is("deleted_at", null)
      .order("sequence_no", { ascending: true });
    if (savedError) return json({ status: "needs_reconciliation", error: "completed_turn_read_failed", retryAllowed: false }, 503);
    return json({ status: "completed", turnId, messages: saved || [], idempotent: true });
  }
  if (!reservation.is_new) {
    if (reservation.charge_status === "refunded" || reservation.turn_status === "failed") {
      return json({ status: "refunded", error: "turn_already_refunded", retryAllowed: false }, 409);
    }
    return json({ status: "needs_reconciliation", error: "turn_already_processing", retryAllowed: false }, 409);
  }

  const { data: group, error: groupError } = await admin.from("chat_groups")
    .select("id,owner_id,name,world_background,scene_mode")
    .eq("id", groupId).eq("owner_id", user.id).is("archived_at", null).maybeSingle();
  if (groupError || !group) {
    const refunded = await refund(admin, user.id, turnId, "group_context_unavailable");
    return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: "group_context_unavailable", balance: refunded.balance, retryAllowed: false }, 503);
  }

  const [memberResult, sceneResult, historyResult, playerResult] = await Promise.all([
    admin.from("chat_group_members")
      .select("id,group_id,character_id,position,scene_id,character_snapshot")
      .eq("group_id", groupId).order("position", { ascending: true }),
    admin.from("chat_group_scenes")
      .select("id,name,description,position").eq("group_id", groupId).order("position", { ascending: true }),
    admin.from("chat_group_messages")
      .select("turn_id,scene_id,speaker_type,character_id,speaker_snapshot,content,created_at,sequence_no")
      .eq("group_id", groupId).is("deleted_at", null)
      .order("created_at", { ascending: false }).limit(40),
    admin.from("profiles").select("id,nickname,persona_presets").eq("id", user.id).maybeSingle(),
  ]);
  if (memberResult.error || sceneResult.error || historyResult.error || playerResult.error ||
      !Array.isArray(memberResult.data) || memberResult.data.length < 1 || memberResult.data.length > 3) {
    const refunded = await refund(admin, user.id, turnId, "group_context_lookup_failed");
    return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: "group_context_unavailable", balance: refunded.balance, retryAllowed: false }, 503);
  }

  const scenes = new Map((sceneResult.data || []).map((scene: any) => [scene.id, scene]));
  const members = memberResult.data as any[];
  const characterIds = members.map(m => m.character_id).filter(isUuid);
  const [charactersResult, privateRowsResult] = await Promise.all([
    characterIds.length ? admin.from("characters")
      .select("id,author_id,name,intro,style,gender,age,race,tags,deleted_at")
      .in("id", characterIds) : Promise.resolve({ data: [], error: null }),
    characterIds.length ? admin.from("character_private_info")
      .select("character_id,author_id,private_info,personality_profile")
      .in("character_id", characterIds) : Promise.resolve({ data: [], error: null }),
  ]);
  if (charactersResult.error || privateRowsResult.error) {
    const refunded = await refund(admin, user.id, turnId, "character_context_lookup_failed");
    return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: "character_context_unavailable", balance: refunded.balance, retryAllowed: false }, 503);
  }

  const characters = new Map((charactersResult.data || []).map((row: any) => [row.id, row]));
  const privateRows = new Map((privateRowsResult.data || []).map((row: any) => [row.character_id, row]));
  const speakers: Speaker[] = [];
  const protectedContext: string[] = [];
  const profileSections: string[] = [];

  for (const member of members) {
    const snapshot = asRow(member.character_snapshot);
    const characterId = asText(member.character_id) || asText(snapshot.id);
    const character = characters.get(characterId) || {};
    const privateInfo = privateRows.get(characterId) || {};
    const scene = scenes.get(member.scene_id) || {};
    const name = asText(snapshot.name) || asText(character.name) || "角色";
    if (!isUuid(characterId) || !name) continue;

    let derivedProfilePrompt = "";
    if (asText(character.author_id)) {
      const { data: derived, error: derivedError } = await admin.rpc("get_character_ai_profile_for_chat", {
        p_character_id: characterId, p_author_id: character.author_id,
      });
      if (!derivedError && derived) {
        derivedProfilePrompt = formatCharacterAiProfilePrompt(derived);
        protectedContext.push(...collectDerivedPrivateProfileValues(derived));
      }
    }
    const rawPrivate = preparePrivateContext(asText(privateInfo.private_info), privateInfo.personality_profile);
    protectedContext.push(...rawPrivate.protectedValues);
    const personality = asText(asRow(privateInfo.personality_profile).personality) ||
      asText(asRow(privateInfo.personality_profile).personality_summary);
    speakers.push({
      id: characterId, name, sceneId: isUuid(member.scene_id) ? member.scene_id : null,
      sceneName: asText(scene.name), snapshot,
    });
    profileSections.push([
      "【角色卡 " + (speakers.length) + "｜" + name + "｜角色 ID " + characterId + "】",
      "身份與背景：" + [asText(character.gender || snapshot.gender), asText(character.age || snapshot.age), asText(character.race || snapshot.race)].filter(Boolean).join("／"),
      "角色介紹：" + (asText(character.intro) || asText(snapshot.intro)),
      "性格與演繹風格：" + [personality, asText(character.style || snapshot.style)].filter(Boolean).join("\n"),
      "標籤：" + JSON.stringify(character.tags || snapshot.tags || []),
      "開場情境：" + asText(snapshot.opening),
      "角色衍生扮演檔：\n" + derivedProfilePrompt,
      "所屬場景 ID：" + asText(member.scene_id) + "｜場景：" + asText(scene.name) + "｜" + asText(scene.description),
    ].join("\n"));
  }
  if (speakers.length !== members.length) {
    const refunded = await refund(admin, user.id, turnId, "group_speaker_snapshot_invalid");
    return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: "group_speaker_snapshot_invalid", balance: refunded.balance, retryAllowed: false }, 503);
  }

  const history = (historyResult.data || []).filter((row: any) => row.turn_id !== turnId).slice().reverse().map((row: any) => {
    const speaker = row.speaker_type === "user" ? "玩家" :
      row.speaker_type === "character" ? (asText(asRow(row.speaker_snapshot).name) || "角色") : "系統";
    return "[場景 " + (asText(row.scene_id) || "共同") + "] " + speaker + "：" + asText(row.content);
  }).filter(Boolean).join("\n");
  const currentMessage = content === "__GROUP_CONTINUE__"
    ? "（玩家沒有輸入新文字，請自然延續目前場景，不要替玩家發言或決定行動。）"
    : content;
  const player = asRow(playerResult.data);
  const playerName = asText(player.nickname) || "玩家";
  const systemPrompt = [
    "你是 POYOZZ 群組互動故事中的唯一 AI 扮演者。你同時讀取所有角色卡，但必須嚴格區分每位角色的人格、記憶、說話方式與場景位置。",
    "【世界與玩家】群組名稱：" + asText(group.name) + "。共同世界觀：" + asText(group.world_background),
    "玩家稱呼：" + playerName + "。玩家是劇情主導者；絕不可替玩家創作台詞、思想、感受、決定或未描述的行動。",
    "【角色卡】\n" + profileSections.join("\n\n").slice(0, 24000),
    "【群組場景模式】" + asText(group.scene_mode) + "。shared 代表角色處於同一共同場景；separate 代表每位角色只知道自己所屬場景，除非對話已合理建立資訊傳遞，否則不可讓角色知道其他場景的即時事件。",
    "【近期群組對話】\n" + history.slice(-14000),
    "【本輪玩家訊息】\n" + currentMessage,
    "【本輪角色選擇與發言規則】每輪由你自行判斷 1～3 名最適合回應的角色，不要求每個角色輪流發言，也不可為了湊人數讓所有人都說話。可以由一位角色回應，也可以讓角色之間自然互動。若玩家明確以 @角色名稱 指定對象，優先由該角色回應，但仍可在劇情確有必要時讓另一角色補充。未被選中的角色保持安靜，不要輸出空白發言。",
    "【角色卡遵循】每位角色只能以自己的角色卡、已知記憶、可觀察資訊和合理推論行動。不得混用人格、口吻或背景；不得擅自替另一角色決定內心或行為。角色可對玩家說話，也可彼此對話。分開場景的角色不得跨場景瞬間出現。",
    "【輸出格式】只輸出純文字，不要 Markdown code fence、JSON 或旁白說明。每段發言必須以角色卡中的精確名稱加全形冒號開始，例如：夜辰：*抬眼看向你*妳終於回來了。若同一角色有多段連續內容，可合併為一段；不同角色必須各自另起一行並重新標記名稱。每段只可使用群組中實際存在的角色名稱。不要輸出「旁白：」「導演：」或未加入群組的人物標記。每輪至少一段、最多三段。角色動作與敘述使用單星號包覆，對白直接書寫。不要替玩家補寫台詞。",
  ].join("\n\n");

  let provider;
  try {
    provider = await requestGeneration([
      { role: "system", content: systemPrompt },
      { role: "user", content: currentMessage },
    ], apiKey);
  } catch (error) {
    // A timeout/network disconnect has an ambiguous provider outcome; keep the
    // reservation locked rather than risk a duplicate generation or double refund.
    return json({ status: "needs_reconciliation", error: error instanceof Error && error.name === "AbortError" ? "provider_timeout_outcome_unknown" : "provider_outcome_unknown", retryAllowed: false }, 503);
  }

  if (provider.result.kind === "content_rejected") {
    const refunded = await refund(admin, user.id, turnId, "provider_content_rejected");
    return json({ status: refunded.confirmed ? "content_rejected" : "needs_reconciliation", balance: refunded.balance, retryAllowed: false }, refunded.confirmed ? 200 : 503);
  }
  if (provider.result.kind !== "generated") {
    const confirmedClientRejection = provider.result.kind === "provider_error" &&
      provider.status >= 400 && provider.status < 500 && provider.status !== 408 && provider.status !== 409 && provider.status !== 429;
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

  const parsed = parseGroupSpeakerOutput(provider.result.text, speakers);
  if (!parsed.length || parsed.length > 3) {
    const refunded = await refund(admin, user.id, turnId, "invalid_speaker_output");
    return json({ status: refunded.confirmed ? "refunded" : "needs_reconciliation", error: "invalid_speaker_output", balance: refunded.balance, retryAllowed: false }, refunded.confirmed ? 200 : 503);
  }

  const speeches = parsed.map(item => ({ speaker_id: item.speakerId, content: item.content }));
  const { data: completed, error: completeError } = await admin.rpc("complete_group_chat_turn", {
    p_user_id: user.id, p_turn_id: turnId, p_speeches: speeches,
  });
  if (completeError || completed !== "completed") {
    // The provider result is known, but persistence may have committed before
    // the acknowledgement was lost. Do not refund or call the model again.
    return json({ status: "needs_reconciliation", error: "group_reply_persistence_unknown", retryAllowed: false }, 503);
  }

  const { data: saved, error: savedError } = await admin.from("chat_group_messages")
    .select("id,group_id,scene_id,turn_id,sequence_no,speaker_type,character_id,speaker_snapshot,content,created_at")
    .eq("group_id", groupId).eq("turn_id", turnId).is("deleted_at", null)
    .order("sequence_no", { ascending: true });
  if (savedError || !saved?.length) return json({ status: "needs_reconciliation", error: "completed_turn_read_failed", retryAllowed: false }, 503);

  return json({
    status: "completed",
    turnId,
    messages: saved,
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
