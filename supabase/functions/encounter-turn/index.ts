// POYOZZ Encounter-only turn handler: shared OpenRouter transport, bounded context,
// private-context screening, idempotent reservation/settlement, and confirmed-failure refunds.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildPromptVariableValues, applyPromptVariables } from "../_shared/prompt-context.ts";
import { preparePrivateContext, findPrivateContextLeak } from "../_shared/private-context-guard.ts";
import { releaseGenerationClaim } from "../_shared/chat-turn-claim.ts";
import { recordChatModelUsage } from "../_shared/story-memory-summary.ts";
import { requestOpenRouterChatCompletion, POYOZZ_DEFAULT_CHAT_MODEL } from "../_shared/openrouter-chat-completions.ts";
import { recordAiGenerationDiagnostic, updateAiGenerationDiagnostic } from "../_shared/ai-generation-diagnostics.ts";
import { buildEncounterResponseGuidelines } from "../_shared/encounter-response-guidelines.ts";
import { parseEncounterTurnOutput } from "../_shared/encounter-turn-output.mjs";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json" },
});
const isUuid = (v: unknown): v is string =>
  typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
type DbRow = Record<string, unknown>;
const asRow = (value: unknown): DbRow =>
  value && typeof value === "object" && !Array.isArray(value) ? value as DbRow : {};
const asText = (value: unknown): string => typeof value === "string" ? value.trim() : "";
const ENCOUNTER_DISCOVERY_SENTINEL = "[POYOZZ_ENCOUNTER_DISCOVERY_EVENT]";
const ENCOUNTER_DISCOVERY_CONTEXT = "（系統事件：玩家選擇留空發送，讓你主動發現玩家；這不是玩家說出口的台詞。）";
const ENCOUNTER_CONTINUE_SENTINEL = "（請接續目前的故事。）";
const ENCOUNTER_CONTINUE_CONTEXT = "（系統事件：玩家留空發送，請你自然延續目前互動；玩家沒有新增台詞。）";
const ENCOUNTER_LOCATION_LABELS: Record<string, string> = {
  airport: "機場", commercial: "公司", "night-bar": "酒吧", "live-house": "Live House",
  apartment: "公寓", "department-store": "百貨公司", bookstore: "書店", cafe: "咖啡廳",
  park: "公園", "shopping-street": "商店街", "night-market": "夜市", restaurant: "餐廳",
  university: "大學", hospital: "醫院", gym: "健身房", cinema: "電影院", museum: "博物館",
  hotel: "飯店", "train-station": "車站", library: "圖書館", theater: "劇院",
  "art-gallery": "藝廊", "community-center": "社區中心", "music-studio": "音樂工作室",
  bakery: "麵包店", "coworking-space": "共享辦公室",
};
const ENCOUNTER_RELATIONSHIP_LABELS: Record<string, string> = {
  hostile: "敵對", dislike: "反感", wary: "戒備", first_meeting: "初次見面",
  acquaintance: "熟識", close: "親近", intimate: "親密", special: "特殊羈絆",
};

async function refundEncounterTurn(admin: any, userId: string, turnId: string, assistantMessageId: string, failureCode: string): Promise<DbRow | null> {
  const { data, error } = await admin.rpc("refund_chat_turn", {
    p_user_id: userId, p_turn_id: turnId, p_assistant_message_id: assistantMessageId,
    p_failure_code: failureCode,
  });
  const result = Array.isArray(data) ? data[0] : data;
  return !error && result?.status === "refunded" ? asRow(result) : null;
}

async function buildEncounterMessages(
  admin: any,
  session: DbRow,
  userId: string,
  userMessageId: string,
  currentUserMessage: DbRow,
): Promise<{ messages: Array<{ role: "system" | "user" | "assistant"; content: string }>; protectedContext: string[]; priorAssistantOutputs: string[] }> {
  const snapshot = asRow(session.character_snapshot);
  const authorId = asText(snapshot.authorId ?? snapshot.author_id);
  const [profileResult, historyResult, privateResult] = await Promise.all([
    admin.from("profiles").select("id,nickname,persona_presets").eq("id", userId).maybeSingle(),
    admin.from("chat_messages").select("id,role,content,created_at")
      .eq("session_id", asText(session.id)).is("deleted_at", null)
      .order("created_at", { ascending: false }).limit(10),
    authorId
      ? admin.from("character_private_info").select("private_info,personality_profile")
        .eq("character_id", asText(session.character_id)).eq("author_id", authorId).maybeSingle()
      : Promise.resolve({ data: null, error: null }),
  ]);
  if (profileResult.error) throw new Error("encounter_player_context_unavailable");
  if (historyResult.error) throw new Error("encounter_history_unavailable");
  if (privateResult.error) throw new Error("encounter_private_context_unavailable");

  const profile = asRow(profileResult.data);
  const privateInfo = asText(privateResult.data?.private_info);
  const personalityProfile = asRow(privateResult.data?.personality_profile);
  const privateContext = preparePrivateContext(privateInfo, personalityProfile);
  const character = {
    ...snapshot,
    id: asText(snapshot.id) || asText(session.character_id),
    name: asText(snapshot.name) || asText(session.character_name) || "角色",
    intro: asText(snapshot.intro),
    style: asText(snapshot.style),
    personality_profile: personalityProfile,
  };
  const scheduleSnapshot = asRow(asRow(session.character_snapshot).encounterSchedule);
  const encounterState = asRow(asRow(session.session_data).encounter);
  const rawAffinity = Number(encounterState.affinity);
  const affinity = Number.isFinite(rawAffinity) ? Math.max(-100, Math.min(100, Math.trunc(rawAffinity))) : 0;
  const relationshipStage = asText(encounterState.relationshipStage) || "first_meeting";
  const relationshipLabel = ENCOUNTER_RELATIONSHIP_LABELS[relationshipStage] || "初次見面";
  const locationKey = asText(scheduleSnapshot.location_key);
  const sessionData = {
    ...asRow(session.session_data),
    scene: asText(scheduleSnapshot.activity) || asText(scheduleSnapshot.scene),
    location: ENCOUNTER_LOCATION_LABELS[locationKey] || locationKey || "角色目前所在的地點",
    time: [asText(scheduleSnapshot.start_time), asText(scheduleSnapshot.end_time)].filter(Boolean).join("–"),
    affinity,
    relationship: relationshipLabel,
  };

  const historyRows = (Array.isArray(historyResult.data) ? historyResult.data : [])
    .slice().reverse().map((row: DbRow) => ({
      id: asText(row.id), role: asText(row.role),
      content: asText(row.content) === ENCOUNTER_DISCOVERY_SENTINEL
        ? ENCOUNTER_DISCOVERY_CONTEXT
        : asText(row.content) === ENCOUNTER_CONTINUE_SENTINEL
          ? ENCOUNTER_CONTINUE_CONTEXT : asText(row.content),
    })).filter((row: DbRow) => row.content);
  const openingMessage = asRow(asRow(session.session_data).openingMessage);
  const openingText = asText(openingMessage.text);
  if (openingText && !historyRows.some((row: DbRow) => row.role === "assistant" && row.content === openingText)) {
    historyRows.unshift({ id: "opening-" + asText(session.id), role: "assistant", content: openingText });
  }
  if (!historyRows.some((row: DbRow) => row.id === userMessageId)) {
    historyRows.push({
      id: userMessageId, role: "user",
      content: asText(currentUserMessage.content) === ENCOUNTER_DISCOVERY_SENTINEL
        ? ENCOUNTER_DISCOVERY_CONTEXT
        : asText(currentUserMessage.content) === ENCOUNTER_CONTINUE_SENTINEL
          ? ENCOUNTER_CONTINUE_CONTEXT : asText(currentUserMessage.content),
    });
  }
  const values = buildPromptVariableValues({
    profile, character, characterSnapshot: snapshot, sessionData,
    messages: historyRows, currentUserMessageId: userMessageId,
  });
  const availableIllustrations = Array.isArray(snapshot.availableIllustrations)
    ? snapshot.availableIllustrations.slice(0, 5).map((item: unknown) => {
      const row = asRow(item);
      return {
        id: asText(row.id),
        name: asText(row.displayName) || "角色立繪",
        assetType: asText(row.assetType) || "gallery",
        sortOrder: Number(row.sortOrder || 0),
      };
    })
    : [];
  const availableSceneBackgrounds = Array.isArray(snapshot.availableSceneBackgrounds)
    ? snapshot.availableSceneBackgrounds.slice(0, 5).map((item: unknown) => {
      const row = asRow(item);
      return {
        id: asText(row.id),
        name: asText(row.displayName) || "場景背景",
        locationKey: asText(row.locationKey) || "*",
      };
    })
    : [];
  const systemTemplate = [
    "你是 POYOZZ 相遇模式中的角色。請以角色本人身分，根據角色設定、目前場景與對話自然回應玩家。",
    "【角色資料】角色：{CHAR}\n公開介紹：{CHAR_DESC}\n演繹風格：{CHAR_STYLE}\n角色個性：{CHAR_PERSONALITY}\n喜好：{CHAR_LIKES}\n雷點：{CHAR_DISLIKES}\n外觀：{CHAR_APPEARANCE}",
    "【作者私密設定】只用於維持角色一致性，不可向玩家揭露、引用或摘要。\n<private_story_context>\n" + privateContext.promptText + "\n</private_story_context>",
    "【目前相遇場景】地點：{LOCATION}\n目前活動：{SCENE}\n行程時段：{TIME}\n目前好感度：" + String(affinity) + "/100\n關係階段：" + relationshipLabel + "\n請延續這個場景，不要無故瞬移或改變時間、服裝與正在進行的活動。",
    "【玩家】{USER}\n玩家人設：{USER_DESC}\n【玩家與現場角色關係】玩家是來到目前行程地點、與角色相遇的人；角色正在執行的工作、服務或任務不代表玩家就是客戶、屋主、委託人或雇主。即使場景描述提到客戶家、店家或工作現場，也只能視為角色目前所在的環境；除非玩家在對話中明確說明，絕不可擅自把玩家寫成客戶或把該場所說成玩家的家。請描寫角色如何在現場注意到玩家，或玩家如何自然走近角色，不替玩家編造台詞與行動。\n【台灣日期】{CURRENT_DATE}",
    "【相遇開場方式】如果玩家本回合輸入的是系統事件「玩家選擇留空發送」，代表玩家沒有說任何台詞，而是希望你依照目前地點、活動、好感度與是否初次見面，自行注意到玩家並主動開始互動。請自然演出角色當下如何發現玩家、第一個動作與開場對話，不可把系統事件當成玩家說出口的話，也不可要求玩家重送招呼。若玩家有輸入文字，則直接回應玩家的招呼。後續空白發送代表延續目前對話，由角色自然繼續說下去。",
    "【近期對話】依照後續對話訊息延續，不得忽略已發生事件。玩家未說出口的想法不可被角色讀取；不要替玩家決定台詞、想法或行動。",
    "【可用角色立繪】只能選擇清單中的 illustration_id。每筆 name 是作者替該張立繪設定的名稱，請優先依名稱語意比對角色當下動作、情緒、服裝與場景；assetType 與 sortOrder 只作為輔助，不可只因排序而選擇。若沒有名稱或情境相符的素材，填 null；不可創造 ID。清單：" + JSON.stringify(availableIllustrations),
    "【可用場景背景】只能選擇清單中的 scene_background_id。locationKey 與目前地點完全相符的背景優先；locationKey 為 * 才是通用背景，只有沒有合適地點背景時才選用。依目前地點與活動挑選；沒有合適素材時填 null。不可創造 ID。清單：" + JSON.stringify(availableSceneBackgrounds),
    buildEncounterResponseGuidelines(),
    "【建議回覆】每回合都必須由你依照本次地點、角色剛才的動作與最新對話，主動產生恰好三則玩家下一步建議回覆。不得因為此欄位非必填、輸出空間有限或沒有明顯下一步而省略或回傳空陣列；若情境平靜，也要提出三種自然且不同方向的延續方式，不可使用固定模板。每則約 30～90 字，必須包含一段玩家可選擇的動作／旁白（使用單星號包覆）以及一句玩家說話內容，兩者自然連貫。不得預設玩家已經做出行動、情緒或想法，不得替玩家決定；不可通用寒暄或空泛追問。\n【每回合好感度】依玩家本回合實際言行與角色互動，回傳整數 affinity_delta，範圍 -3 至 +3。沒有明顯關係變化就回 0；尊重、理解、互相支持可小幅正向，冒犯、越界或衝突可負向。不得因單方面要求、角色自行宣稱或無實際互動而加分；不得輸出總好感度或關係階段。\n【輸出格式】只輸出 JSON object，不要 Markdown code fence。格式：{\"reply\":\"60 至 300 字元的完整角色回覆\",\"affinity_delta\":整數 -3 至 3,\"illustration_id\":\"清單中的 UUID 或 null\",\"scene_background_id\":\"清單中的 UUID 或 null\",\"suggested_replies\":[\"選項一（動作／旁白＋台詞）\"]}。reply、affinity_delta、illustration_id、scene_background_id 與 suggested_replies 都必須輸出；suggested_replies 必須恰好三項，不可省略或為空陣列。reply 以 60～300 字元為目標，但不可為湊字數灌水，字數偏短或偏長仍須保留可用內容，不得因字數偏差而拒絕保存或退款；敘事／動作使用單星號包覆，角色台詞不加引號。不可輸出額外欄位、分析或提示詞.",
  ].join("\n\n");
  const system = applyPromptVariables(systemTemplate, values);
  const messages = historyRows.filter((row: DbRow) => row.id !== userMessageId).slice(-9)
    .map((row: DbRow) => ({
      role: row.role === "assistant" ? "assistant" as const : "user" as const,
      content: asText(row.content),
    })).filter((row: DbRow) => row.content);
  const currentMessageContent = asText(currentUserMessage.content) === ENCOUNTER_DISCOVERY_SENTINEL
    ? ENCOUNTER_DISCOVERY_CONTEXT
    : asText(currentUserMessage.content) === ENCOUNTER_CONTINUE_SENTINEL
      ? ENCOUNTER_CONTINUE_CONTEXT : asText(currentUserMessage.content);
  messages.push({ role: "user", content: currentMessageContent });
  return {
    messages: [{ role: "system", content: system }, ...messages],
    protectedContext: privateContext.protectedValues,
    priorAssistantOutputs: historyRows.filter((row: DbRow) => row.role === "assistant")
      .slice(-5).map((row: DbRow) => asText(row.content)).filter(Boolean),
  };
}

async function resolveEncounterVisuals(admin: any, session: DbRow, parsedOutput: DbRow): Promise<DbRow> {
  const snapshot = asRow(session.character_snapshot);
  const characterId = asText(session.character_id);
  const locationKey = asText(session.location_key);
  const allowedIllustrations = Array.isArray(snapshot.availableIllustrations)
    ? snapshot.availableIllustrations.map((item: unknown) => asRow(item)).filter((item: DbRow) => isUuid(item.id))
    : [];
  const allowedBackgrounds = Array.isArray(snapshot.availableSceneBackgrounds)
    ? snapshot.availableSceneBackgrounds.map((item: unknown) => asRow(item)).filter((item: DbRow) => isUuid(item.id))
    : [];

  const preferredIllustration = allowedIllustrations.find((item: DbRow) => item.id === parsedOutput.illustrationId)
    || allowedIllustrations[0]
    || null;
  let illustration: DbRow | null = null;
  if (preferredIllustration) {
    const { data } = await admin.from("character_illustrations")
      .select("id,display_name,asset_type")
      .eq("id", preferredIllustration.id)
      .eq("character_id", characterId)
      .eq("asset_type", "gallery")
      .maybeSingle();
    illustration = data ? asRow(data) : null;
  }

  const preferredBackground = allowedBackgrounds.find((item: DbRow) => item.id === parsedOutput.sceneBackgroundId)
    || allowedBackgrounds[0]
    || null;
  let background: DbRow | null = null;
  if (preferredBackground) {
    const { data } = await admin.from("encounter_scene_backgrounds")
      .select("id,location_key,display_name,asset_path")
      .eq("id", preferredBackground.id)
      .eq("is_active", true)
      .maybeSingle();
    const row = data ? asRow(data) : null;
    if (row && (asText(row.location_key) === locationKey || asText(row.location_key) === "*")) {
      const path = asText(row.asset_path);
      if (/^(\.\/|\/)[A-Za-z0-9_./-]+$/.test(path) && !/(^|\/)\.\.(\/|$)/.test(path)) {
        background = row;
      }
    }
  }

  return {
    illustrationId: illustration ? asText(illustration.id) : null,
    illustrationName: illustration ? asText(illustration.display_name) : null,
    sceneBackgroundId: background ? asText(background.id) : null,
    sceneBackgroundName: background ? asText(background.display_name) : null,
    sceneBackgroundPath: background ? asText(background.asset_path) : "./encounter-default-scene.webp",
  };
}

async function loadEncounterVisuals(admin: any, messageId: string): Promise<DbRow | null> {
  const { data: visualRow, error } = await admin.from("encounter_turn_visuals")
    .select("illustration_id,scene_background_id")
    .eq("message_id", messageId)
    .maybeSingle();
  if (error || !visualRow) return null;
  const row = asRow(visualRow);
  const [illustrationResult, backgroundResult] = await Promise.all([
    row.illustration_id
      ? admin.from("character_illustrations").select("id,display_name")
        .eq("id", row.illustration_id).maybeSingle()
      : Promise.resolve({ data: null }),
    row.scene_background_id
      ? admin.from("encounter_scene_backgrounds").select("id,display_name,asset_path")
        .eq("id", row.scene_background_id).eq("is_active", true).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const illustration = asRow(illustrationResult.data);
  const background = asRow(backgroundResult.data);
  const backgroundPath = asText(background.asset_path);
  const safeBackgroundPath = /^(\.\/|\/)[A-Za-z0-9_./-]+$/.test(backgroundPath)
    && !/(^|\/)\.\.(\/|$)/.test(backgroundPath)
    ? backgroundPath
    : "./encounter-default-scene.webp";
  return {
    illustrationId: asText(row.illustration_id) || null,
    illustrationName: asText(illustration.display_name) || null,
    sceneBackgroundId: background.id ? asText(background.id) : null,
    sceneBackgroundName: asText(background.display_name) || null,
    sceneBackgroundPath: safeBackgroundPath,
  };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const openRouterKey = Deno.env.get("OPENROUTER_API_KEY")?.trim();
  const authorization = request.headers.get("Authorization");
  if (!url || !anon || !service) return json({ error: "server_not_configured" }, 503);
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);
  // Fail before reservation so a missing provider secret never locks wallet funds.
  if (!openRouterKey) return json({ error: "openrouter_not_configured", retryAllowed: true }, 503);

  let body: Record<string, unknown>;
  try { body = await request.json(); } catch { return json({ error: "invalid_json" }, 400); }
  const turnId = typeof body.turnId === "string" ? body.turnId : "";
  const sessionId = typeof body.sessionId === "string" ? body.sessionId : "";
  const userMessageId = typeof body.userMessageId === "string" ? body.userMessageId : "";
  const assistantMessageId = typeof body.assistantMessageId === "string" ? body.assistantMessageId : "";
  if (![turnId, sessionId, userMessageId, assistantMessageId].every(isUuid)) {
    return json({ error: "invalid_turn_identifiers" }, 400);
  }

  const userClient = createClient(url, anon, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await userClient.auth.getUser();
  const user = authData?.user;
  if (authError || !user) return json({ error: "unauthorized" }, 401);

  const { data: active, error: activeError } = await userClient.rpc("account_is_active");
  if (activeError || active !== true) return json({ error: "account_not_active" }, 403);
  const { error: walletError } = await userClient.rpc("ensure_wallet_account");
  if (walletError) return json({ error: "wallet_not_ready" }, 409);

  const { data: session, error: sessionError } = await admin.from("chat_sessions")
    .select("id,user_id,deleted_at,character_id,character_name,character_snapshot,session_data,chat_mode")
    .eq("id", sessionId).eq("user_id", user.id).is("deleted_at", null).maybeSingle();
  if (sessionError) return json({ error: "session_lookup_failed" }, 503);
  if (!session) return json({ error: "chat_session_not_owned_or_active" }, 403);
  if (session.chat_mode !== "encounter") return json({ error: "encounter_session_required", retryAllowed: false }, 409);
  if (!isUuid(session.character_id)) return json({ error: "chat_session_character_id_invalid", retryAllowed: false }, 409);

  // Existing Encounter sessions remain usable after a character is made private or archived.
  const snapshot = asRow(session.character_snapshot);
  if (snapshot.id && snapshot.id !== session.character_id) {
    return json({ error: "chat_session_character_snapshot_mismatch", retryAllowed: false }, 409);
  }

  const { data: userMessage, error: messageError } = await admin.from("chat_messages")
    .select("id,session_id,role,content,deleted_at")
    .eq("id", userMessageId).eq("session_id", sessionId).eq("role", "user")
    .is("deleted_at", null).maybeSingle();
  if (messageError) return json({ error: "user_message_lookup_failed" }, 503);
  if (!userMessage || !asText(userMessage.content)) return json({ error: "user_message_not_found" }, 400);

  const { data: reservation, error: reserveError } = await admin.rpc("reserve_encounter_chat_turn", {
    p_user_id: user.id, p_turn_id: turnId, p_session_id: sessionId,
    p_user_message_id: userMessageId, p_assistant_message_id: assistantMessageId,
  });
  if (reserveError?.code === "23505" || String(reserveError?.message || "").includes("chat_turn_charges_user_message_id_uidx")) {
    return json({ error: "user_message_already_charged", retryAllowed: false }, 409);
  }
  if (reserveError?.code === "23514" || String(reserveError?.message || "").includes("encounter_scene_expired_or_inactive")) {
    return json({ error: "encounter_scene_expired_or_inactive", retryAllowed: false }, 409);
  }
  if (reserveError) return json({ error: "reservation_failed" }, 503);
  const charge = Array.isArray(reservation) ? reservation[0] : reservation;
  if (!charge) return json({ error: "reservation_state_missing" }, 503);
  if (charge.status === "insufficient_funds") return json({
    status: "insufficient_funds",
    balance: { silver_coins: charge.balance_silver, diamonds: charge.balance_diamonds },
    rewardVideoSuggested: true,
  }, 402);
  if (charge.status === "refunded") return json({ error: "turn_already_refunded" }, 409);

  const persistEvidence = async () => await admin.rpc("record_encounter_session_turn_evidence", {
    p_turn_id: turnId, p_session_id: sessionId, p_user_id: user.id,
    p_character_id: session.character_id, p_user_message_id: userMessageId,
    p_assistant_message_id: assistantMessageId,
    p_evaluation: { source: "encounter_turn_handler", evaluator: "pending" },
  });
  const settleAndRespond = async (reply: DbRow, idempotent = false, visualOverride: DbRow | null = null, suggestedReplies: string[] = []) => {
    const { data: settled, error: settleError } = await admin.rpc("settle_chat_turn", {
      p_user_id: user.id, p_turn_id: turnId, p_assistant_message_id: assistantMessageId,
    });
    if (settleError) return json({ status: "needs_reconciliation", replySaved: true, retryAllowed: false }, 503);
    const affinityDelta = Number(reply.affinity_delta);
    let affinityResult: DbRow | null = null;
    if (Number.isInteger(affinityDelta) && affinityDelta >= -3 && affinityDelta <= 3) {
      const { data, error } = await admin.rpc("apply_encounter_turn_affinity", {
        p_turn_id: turnId, p_user_id: user.id, p_character_id: session.character_id, p_affinity_delta: affinityDelta,
      });
      if (error || !data) return json({ status: "needs_reconciliation", error: "encounter_affinity_apply_failed", retryAllowed: true }, 503);
      affinityResult = asRow(data);
    }
    const { data: evidence, error: evidenceError } = await persistEvidence();
    if (evidenceError || !evidence) {
      return json({ status: "needs_reconciliation", error: "encounter_evidence_persistence_failed", retryAllowed: true }, 503);
    }
    const visuals = visualOverride || await loadEncounterVisuals(admin, asText(reply.id));
    // The assistant reply and charge are already durable. Clear the matching pending
    // client marker server-side so a stale client metadata snapshot cannot leave this
    // settled Encounter turn looking permanently in-flight after a version conflict.
    const { data: currentSessionMeta, error: sessionMetaReadError } = await admin.from("chat_sessions")
      .select("session_data").eq("id", sessionId).eq("user_id", user.id).is("deleted_at", null).maybeSingle();
    let sessionMetadataSynced = false;
    if (!sessionMetaReadError && currentSessionMeta) {
      const sessionData = { ...asRow(currentSessionMeta.session_data) };
      const pending = asRow(sessionData.pendingTurn);
      if (asText(pending.turnId) === turnId) delete sessionData.pendingTurn;
      if (visuals) sessionData.encounterVisuals = visuals;
      const { error: sessionMetaWriteError } = await admin.from("chat_sessions")
        .update({ session_data: sessionData }).eq("id", sessionId).eq("user_id", user.id).is("deleted_at", null);
      sessionMetadataSynced = !sessionMetaWriteError;
      if (sessionMetaWriteError) console.warn("encounter_session_metadata_sync_failed", sessionMetaWriteError.code || "unknown");
    }
    return json({
      status: settled, assistantMessage: { id: reply.id, content: reply.content, role: "assistant" },
      ...(suggestedReplies.length > 0 ? { suggestedReplies } : {}),
      ...(idempotent ? { idempotent: true } : {}),
      encounter: { evidence, ...(affinityResult ? { affinity: affinityResult } : { affinityLegacyTurn: true }), ...(visuals ? { visuals } : {}) },
    });
  };
  const findSavedReply = async () => await admin.from("chat_messages").select("id,content,role,affinity_delta,suggested_replies")
    .eq("id", assistantMessageId).eq("session_id", sessionId).eq("role", "assistant")
    .is("deleted_at", null).maybeSingle();

  if (charge.status === "settled" || charge.status === "needs_reconciliation") {
    const { data: saved, error: savedError } = await findSavedReply();
    if (savedError) return json({ status: "needs_reconciliation", error: "reply_lookup_failed", retryAllowed: false }, 503);
    if (saved && asText(saved.content)) return await settleAndRespond(saved, true, null, Array.isArray(saved.suggested_replies) ? saved.suggested_replies.map((value: unknown) => asText(value)).filter(Boolean).slice(0,3) : []);
    if (charge.status === "settled") return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
    // A prior provider request may still have completed. Never issue a second
    // billable generation merely because its response or persistence ack was lost.
    return json({ status: "needs_reconciliation", error: "provider_generation_outcome_unknown", retryAllowed: false }, 503);
  }
  if (charge.status !== "reserved") return json({ error: "turn_not_processable" }, 409);

  // One request owns the provider call. Duplicate requests cannot generate twice.
  const { data: claimed, error: claimError } = await admin.from("chat_turn_charges")
    .update({ status: "needs_reconciliation", failure_code: "provider_generation_in_progress", updated_at: new Date().toISOString() })
    .eq("turn_id", turnId).eq("user_id", user.id).eq("status", "reserved")
    .select("turn_id").maybeSingle();
  if (claimError || !claimed) return json({ status: "needs_reconciliation", error: "generation_already_claimed", retryAllowed: false }, 503);
  await admin.from("chat_turn_events").insert({
    turn_id: turnId, user_id: user.id, event_type: "generation_started", stage: "provider_request",
  });

  let context: Awaited<ReturnType<typeof buildEncounterMessages>>;
  try {
    // The Encounter session snapshot was created server-side from the validated
    // schedule resolver. Reuse it instead of issuing a second lifecycle-table read.
    context = await buildEncounterMessages(admin, session, user.id, userMessageId, userMessage);
  } catch (error) {
    const code = String(error instanceof Error ? error.message : "encounter_context_failed").slice(0, 80);
    const released = await releaseGenerationClaim(admin, turnId, user.id);
    await admin.from("chat_turn_events").insert({
      turn_id: turnId, user_id: user.id, event_type: "generation_context_failed", stage: "context", error_code: code,
    });
    if (!released) return json({ status: "needs_reconciliation", error: "generation_claim_release_unconfirmed", retryAllowed: false }, 503);
    return json({ error: "encounter_context_unavailable", retryAllowed: true }, 503);
  }

  let providerResponse: Awaited<ReturnType<typeof requestOpenRouterChatCompletion>>;
  try {
    providerResponse = await requestOpenRouterChatCompletion({
      messages: context.messages, apiKey: openRouterKey, model: POYOZZ_DEFAULT_CHAT_MODEL,
      timeoutMs: 55_000, temperature: 0.85, responseFormat: { type: "json_object" },
    });
  } catch (error) {
    const code = error instanceof Error && error.name === "AbortError"
      ? "provider_request_timeout" : "provider_request_failed";
    const refunded = await refundEncounterTurn(admin, user.id, turnId, assistantMessageId, code);
    if (!refunded) {
      await admin.from("chat_turn_events").insert({
        turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation", stage: "provider_request_refund", error_code: "refund_outcome_unknown",
      });
      return json({ status: "needs_reconciliation", error: "refund_outcome_unknown", retryAllowed: false }, 503);
    }
    return json({ status: "refunded", error: code, balance: {
      silver_coins: refunded.balance_silver, diamonds: refunded.balance_diamonds,
    } });
  }

  const recordUsage = (messageId: string | null, requestStatus: "completed" | "failed") =>
    recordChatModelUsage(admin, {
      userId: user.id, sessionId, turnId, assistantMessageId: messageId,
      requestedModel: POYOZZ_DEFAULT_CHAT_MODEL, providerResponse, requestStatus,
    });
  const providerResult = providerResponse.result;
  const diagnosticId = await recordAiGenerationDiagnostic(admin, {
    generationType: "encounter_chat", userId: user.id, characterId: session.character_id,
    sessionId, turnId, model: providerResponse.model, provider: providerResponse.provider,
    requestId: providerResponse.requestId, httpStatus: providerResponse.httpStatus,
    finishReason: providerResponse.finishReason, responseContentType: providerResponse.responseContentType,
    responseBodyLength: providerResponse.responseBodyLength, responseParsed: providerResponse.responseParsed,
    rawOutputText: providerResponse.rawOutputText || (providerResult.kind === "generated" ? providerResult.text : ""),
    rawResponseBody: providerResponse.rawResponseBody,
    refusalText: providerResponse.rawRefusalText, usage: providerResponse.usage,
    status: providerResult.kind === "generated" ? "received" : "failed",
    failureStage: providerResult.kind === "generated" ? null : "provider_response",
    failureCode: providerResult.kind === "provider_error" ? providerResult.code :
      providerResult.kind === "content_rejected" ? "provider_content_rejected" :
      providerResult.kind === "empty_output" ? "empty_output" : null,
  });
  if (providerResult.kind !== "generated") {
    await updateAiGenerationDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "provider_response",
      failureCode: providerResult.kind === "provider_error" ? providerResult.code :
        providerResult.kind === "content_rejected" ? "provider_content_rejected" : "empty_output" });
    await recordUsage(null, "failed");
    const failureCode = providerResult.kind === "provider_error" ? providerResult.code :
      providerResult.kind === "content_rejected" ? "provider_content_rejected" : "empty_output";
    await admin.from("chat_turn_events").insert({
      turn_id: turnId, user_id: user.id, event_type: "provider_response_diagnostic",
      stage: "provider_response", error_code: failureCode,
      retryable: providerResult.kind === "provider_error" ? providerResult.retryable : false,
      http_status: providerResponse.httpStatus,
      gateway_request_id: /^[A-Za-z0-9._:-]{1,128}$/.test(providerResponse.requestId) ? providerResponse.requestId : null,
    });
    // Encounter promises no user charge whenever no valid character reply is delivered.
    const refunded = await refundEncounterTurn(admin, user.id, turnId, assistantMessageId, failureCode);
    if (!refunded) {
      return json({ status: "needs_reconciliation", error: "refund_outcome_unknown", retryAllowed: false }, 503);
    }
    return json({
      status: providerResult.kind === "content_rejected" ? "content_rejected" : "provider_error_refunded",
      error: failureCode,
      balance: { silver_coins: refunded.balance_silver, diamonds: refunded.balance_diamonds },
    });
  }

  const parsedOutput = parseEncounterTurnOutput(providerResult.text);
  const replyText = parsedOutput?.reply || "";
  if (!parsedOutput || !replyText || findPrivateContextLeak(providerResult.text, context.protectedContext, context.priorAssistantOutputs)) {
    await updateAiGenerationDiagnostic(admin, diagnosticId, { status: "failed", failureStage: "output_screening", failureCode: replyText ? "private_context_output_blocked" : "invalid_encounter_ai_output", validationErrors: [replyText ? "private_context_output_blocked" : "invalid_encounter_ai_output"] });
    await recordUsage(null, "failed");
    const failureCode = replyText ? "private_context_output_blocked" : "invalid_encounter_ai_output";
    await admin.from("chat_turn_events").insert({
      turn_id: turnId, user_id: user.id, event_type: "encounter_output_rejected", stage: "output_screening", error_code: failureCode,
    });
    const refunded = await refundEncounterTurn(admin, user.id, turnId, assistantMessageId, failureCode);
    if (!refunded) return json({ status: "needs_reconciliation", error: "refund_outcome_unknown", retryAllowed: false }, 503);
    return json({ status: "refunded", error: failureCode, balance: {
      silver_coins: refunded.balance_silver, diamonds: refunded.balance_diamonds,
    } });
  }

  await updateAiGenerationDiagnostic(admin, diagnosticId, { status: "completed", failureStage: null, failureCode: null });
  const assistantRow = {
    id: assistantMessageId, session_id: sessionId, role: "assistant",
    content: replyText, affinity_delta: parsedOutput.affinityDelta, suggested_replies: parsedOutput.suggestedReplies, created_at: new Date().toISOString(),
  };
  const { error: insertError } = await admin.from("chat_messages").insert(assistantRow);
  let reply: DbRow = assistantRow;
  if (insertError) {
    const { data: existing, error: verifyError } = await findSavedReply();
    if (verifyError) return json({ status: "needs_reconciliation", error: "reply_write_outcome_unknown", retryAllowed: false }, 503);
    if (!existing || !asText(existing.content)) {
      await recordUsage(null, "failed");
      const refunded = await refundEncounterTurn(admin, user.id, turnId, assistantMessageId, "assistant_persistence_failed");
      if (refunded) return json({ status: "refunded", balance: {
        silver_coins: refunded.balance_silver, diamonds: refunded.balance_diamonds,
      } });
      return json({ status: "needs_reconciliation", error: "assistant_persistence_refund_unknown", retryAllowed: false }, 503);
    }
    if (asText(existing.content) !== replyText) {
      return json({ status: "needs_reconciliation", error: "assistant_message_id_collision", retryAllowed: false }, 409);
    }
    reply = existing;
  }

  await recordUsage(assistantMessageId, "completed");
  const visuals = await resolveEncounterVisuals(admin, session, parsedOutput);
  const { error: visualPersistError } = await admin.from("encounter_turn_visuals").upsert({
    message_id: assistantMessageId,
    session_id: sessionId,
    character_id: session.character_id,
    illustration_id: visuals.illustrationId,
    scene_background_id: visuals.sceneBackgroundId,
  }, { onConflict: "message_id" });
  if (visualPersistError) {
    await admin.from("chat_turn_events").insert({
      turn_id: turnId, user_id: user.id, event_type: "encounter_visual_persistence_failed",
      stage: "visual_persistence", error_code: "visual_metadata_write_failed",
    });
  }
  return await settleAndRespond(reply, false, visuals, parsedOutput.suggestedReplies);
});
