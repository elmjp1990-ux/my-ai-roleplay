import {
  type EncounterSceneCatalogEntry,
  buildEncounterScheduleBatchMessages,
  isEncounterModernMapCompatible,
  normalizeEncounterSceneKey,
  resolveEncounterScheduleAvailability,
  parseEncounterScheduleBatchOutput,
} from "./encounter-schedule-generation.ts";

const id1 = "11111111-1111-4111-8111-111111111111";
const author = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const greeting = "相遇內容。".repeat(30);
const relationshipStages = [
  "hostile", "dislike", "wary", "first_meeting",
  "acquaintance", "close", "intimate", "special",
];
const relationshipGreetings = () => Object.fromEntries(relationshipStages.map((stage) => [
  stage,
  [greeting + stage + "第一版", greeting + stage + "第二版", greeting + stage + "第三版"],
]));
const withGreetingPools = (character: { placement?: string; [key: string]: unknown }) =>
  character.placement === "modern_map" && !("relationship_greetings" in character)
    ? { ...character, relationship_greetings: relationshipGreetings() }
    : character;
const source = (character_id = id1, extra = {}) => ({
  character_id, author_id: author, visibility: "public", review_status: "approved", rights_confirmed: true, deleted_at: null,
  name: "測試角色", intro: "現代城市生活",
  world_era: "modern", modern_setting_compatible: true, time_travel_explicit: false,
  schedule_description: "白天在公司工作，晚上和朋友見面",
  private_info: "只供角色一致性使用的私密設定", personality_profile: { tone: "溫柔" },
  ...extra,
});
const locationNames: Record<string, string> = {
  airport: "機場", commercial: "公司", "night-bar": "酒吧", "live-house": "Live House",
  apartment: "住家", "department-store": "百貨公司", bookstore: "書店", cafe: "咖啡廳",
  park: "公園", "shopping-street": "商店街", "night-market": "夜市", gym: "健身房",
  hospital: "醫院", library: "圖書館", "train-station": "火車站",
};
const option = (extra = {}): Record<string, unknown> => {
  const row = {
    weight: 100,
    location_key: "commercial",
    activity: "在公司處理工作",
    scene_description: "他站在會議室窗邊整理文件，神情專注，準備開始今天的工作。",
    is_outdoor: false,
    rain_fallback_location_key: null,
    rain_fallback_activity: null,
    rain_fallback_greeting: null,
    encounter_greeting: greeting,
    ...extra,
  } as Record<string, unknown>;
  const locationKey = String(row.location_key || "");
  const fallbackKey = row.rain_fallback_location_key == null ? null : String(row.rain_fallback_location_key);
  delete row.location_key;
  delete row.rain_fallback_location_key;
  return {
    ...row,
    location: locationNames[locationKey] || locationKey,
    rain_fallback_location: fallbackKey ? (locationNames[fallbackKey] || fallbackKey) : null,
  };
};
const block = (start_time: string, end_time: string, options = [option()]) => ({
  start_time, end_time, options,
});
const hourlyBlocks = () => [
  block("06:00", "07:00", [
    option({ weight: 80, location_key: "apartment", activity: "睡覺", scene_description: "他縮在被子裡熟睡，房間安靜得只剩空調聲。" }),
    option({ weight: 20, location_key: "apartment", activity: "睡不著", scene_description: "他在床上翻了幾次身，望著窗簾縫隙遲遲沒有睡意。" }),
  ]),
  block("07:00", "08:00", [
    option({ weight: 80, location_key: "apartment", activity: "繼續睡覺", scene_description: "鬧鐘響過一次，他只是皺眉翻身，又沉沉睡去。" }),
    option({ weight: 20, location_key: "apartment", activity: "提早醒來", scene_description: "他終於睜開眼睛，拿起床邊的水喝了幾口。" }),
  ]),
  block("16:00", "17:00", [
    option({ weight: 100, location_key: "apartment", activity: "剛睡醒", scene_description: "他坐在床沿揉揉眼睛，慢慢適應房間裡的昏黃光線。" }),
  ]),
  block("17:00", "18:00", [
    option({ weight: 80, location_key: "shopping-street", activity: "逛商店街並用餐", is_outdoor: true, rain_fallback_location_key: "cafe", rain_fallback_activity: "改在咖啡廳用餐", rain_fallback_greeting: greeting, scene_description: "他沿著商店街慢慢挑選晚餐，偶爾停下來看櫥窗。" }),
    option({ weight: 20, location_key: "apartment", activity: "在家用餐並準備工作", scene_description: "他把簡單的晚餐端到桌上，順手確認晚點工作的用品。" }),
  ]),
];
const variants = (weekday = hourlyBlocks()) => ({
  weekday,
  holiday: [
    block("12:00", "13:00", [
      option({ weight: 70, location_key: "apartment", activity: "在家休息", scene_description: "他把窗簾拉開一些，仍懶洋洋地靠在沙發上。" }),
      option({ weight: 30, location_key: "music-studio", activity: "到舊工作室彈吉他", scene_description: "他坐在熟悉的椅子上調整琴弦，隨手試了幾個和弦。" }),
    ]),
    block("17:00", "18:00", [
      option({ weight: 100, location_key: "restaurant", activity: "外出用餐", scene_description: "他選了靠窗的位置坐下，安靜地翻看菜單。" }),
    ]),
  ],
});
const fullDaySlots = () => [
  {
    start_time: "00:00", end_time: "08:00", location: "住家", activity: "在家休息",
    scene_description: "他在房間裡休息，屋內安靜而昏暗。", is_outdoor: false,
    rain_fallback_location: null, rain_fallback_activity: null, rain_fallback_greeting: null,
    encounter_greeting: greeting,
  },
  {
    start_time: "08:00", end_time: "16:00", location: "公司", activity: "在公司工作",
    scene_description: "他坐在辦公桌前整理資料，準備處理今天的工作。", is_outdoor: false,
    rain_fallback_location: null, rain_fallback_activity: null, rain_fallback_greeting: null,
    encounter_greeting: greeting,
  },
  {
    start_time: "16:00", end_time: "22:00", location: "咖啡廳", activity: "在咖啡廳休息",
    scene_description: "他坐在窗邊喝咖啡，觀察街道上的人群。", is_outdoor: false,
    rain_fallback_location: null, rain_fallback_activity: null, rain_fallback_greeting: null,
    encounter_greeting: greeting,
  },
  {
    start_time: "22:00", end_time: "00:00", location: "住家", activity: "回家休息",
    scene_description: "他回到家中，準備結束今天的生活。", is_outdoor: false,
    rain_fallback_location: null, rain_fallback_activity: null, rain_fallback_greeting: null,
    encounter_greeting: greeting,
  },
];
const builtInSceneCatalog: EncounterSceneCatalogEntry[] = [
  "airport", "commercial", "night-bar", "live-house", "apartment",
  "department-store", "bookstore", "cafe", "park",
].map((location_key) => ({ location_key, display_name: location_key, is_dynamic: false }));
const result = (
  characters: Array<{ character_id: string; [key: string]: unknown }>,
  sourceRows?: ReturnType<typeof source>[],
  sceneCatalog?: EncounterSceneCatalogEntry[],
) => parseEncounterScheduleBatchOutput(
  JSON.stringify({ characters: characters.map(withGreetingPools), scenes: [] }),
  sourceRows ?? characters.map((c) => source(c.character_id)),
  [...builtInSceneCatalog, ...(sceneCatalog ?? [])],
);
const specialEvent = (event_key = "christmas", slots = fullDaySlots()) => ({
  event_key, event_name: ({
    taiwan_public_holiday: "國定假日",
    lunar_new_year: "春節",
    valentines_day: "情人節",
    christmas: "聖誕節",
  } as Record<string, string>)[event_key] ?? "節日", slots,
});

Deno.test("accepts independently weighted hourly options for weekday and holiday schedules", () => {
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants() }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  const first = parsed.characters[0].variants.weekday[0];
  if (first.start_time !== "06:00" || first.end_time !== "07:00" ||
      first.options.length !== 2 || first.options[0].weight !== 80 || first.options[1].weight !== 20) {
    throw new Error("hourly weighted options were not retained");
  }
  if (parsed.characters[0].variants.holiday[0].options[0].weight !== 70) {
    throw new Error("holiday options should have their own independent weights");
  }
});

Deno.test("requires 3-5 distinct greetings for all eight relationship stages", () => {
  const accepted = result([{ character_id: id1, placement: "modern_map", variants: variants() }]);
  if (!accepted.ok) throw new Error(accepted.errors.join(","));
  if (Object.keys(accepted.characters[0].relationship_greetings ?? {}).length !== 8) throw new Error("eight relationship-stage greeting pools were not retained");
  const missingStage = relationshipGreetings();
  delete (missingStage as Record<string, unknown>).special;
  const missing = result([{ character_id: id1, placement: "modern_map", variants: variants(), relationship_greetings: missingStage }]);
  if (missing.ok || !missing.errors.some((error) => error.includes("relationship_greeting_stages_invalid"))) throw new Error("missing relationship stage accepted");
  const tooFew = relationshipGreetings();
  tooFew.close = [greeting, greeting + "第二版"];
  const shortPool = result([{ character_id: id1, placement: "modern_map", variants: variants(), relationship_greetings: tooFew }]);
  if (shortPool.ok || !shortPool.errors.some((error) => error.includes("greeting_pool_count_invalid"))) throw new Error("two-greeting pool accepted");
  const duplicate = relationshipGreetings();
  duplicate.intimate = [greeting, greeting, greeting + "第三版"];
  const duplicates = result([{ character_id: id1, placement: "modern_map", variants: variants(), relationship_greetings: duplicate }]);
  if (duplicates.ok || !duplicates.errors.some((error) => error.includes("greeting_pool_duplicate"))) throw new Error("duplicate greeting accepted");
  const short = relationshipGreetings();
  short.hostile = ["太短", greeting + "第二版", greeting + "第三版"];
  const shortGreeting = result([{ character_id: id1, placement: "modern_map", variants: variants(), relationship_greetings: short }]);
  if (shortGreeting.ok || !shortGreeting.errors.some((error) => error.includes("greeting_pool_length_invalid"))) throw new Error("short relationship greeting accepted");
});

Deno.test("requires a scene-aware greeting for every generated option", () => {
  const blocks = hourlyBlocks();
  blocks[0].options[0] = option({ weight: 80, encounter_greeting: "太短" });
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (parsed.ok || !parsed.errors.some((error) => error.includes("greeting_length_invalid"))) throw new Error("short greeting accepted");
});

Deno.test("rejects overlapping, unsorted, or non-hourly time blocks", () => {
  const overlap = hourlyBlocks();
  overlap[1] = block("06:00", "07:00");
  const overlapResult = result([{ character_id: id1, placement: "modern_map", variants: variants(overlap) }]);
  if (overlapResult.ok || !overlapResult.errors.some((error) => error.includes("hourly_blocks_overlap"))) throw new Error("overlap accepted");
  const nonHourly = hourlyBlocks();
  nonHourly[0] = block("08:30", "09:30");
  const nonHourlyResult = result([{ character_id: id1, placement: "modern_map", variants: variants(nonHourly) }]);
  if (nonHourlyResult.ok || !nonHourlyResult.errors.some((error) => error.includes("must_be_exactly_one_hour"))) throw new Error("non-hour interval accepted");
  const unsorted = hourlyBlocks().reverse();
  const unsortedResult = result([{ character_id: id1, placement: "modern_map", variants: variants(unsorted) }]);
  if (unsortedResult.ok || !unsortedResult.errors.some((error) => error.includes("must_be_sorted"))) throw new Error("unsorted blocks accepted");
});

Deno.test("allows natural gaps and preserves each hour instead of merging repeated activities", () => {
  const blocks = hourlyBlocks();
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].variants.weekday.length !== 4 ||
      parsed.characters[0].variants.weekday[0].end_time !== "07:00" ||
      parsed.characters[0].variants.weekday[1].start_time !== "07:00") {
    throw new Error("hourly intervals were merged or natural schedule data was lost");
  }
});

Deno.test("requires an indoor fallback for each outdoor option", () => {
  const blocks = hourlyBlocks();
  blocks[3].options[0] = option({
    weight: 80, location_key: "park", is_outdoor: true,
    rain_fallback_location_key: "cafe", rain_fallback_activity: "改在咖啡廳休息",
    rain_fallback_greeting: greeting,
  });
  const valid = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (!valid.ok) throw new Error(valid.errors.join(","));
  const invalidBlocks = hourlyBlocks();
  invalidBlocks[3].options[0] = option({
    weight: 80, location_key: "park", is_outdoor: true,
    rain_fallback_location_key: "park", rain_fallback_activity: "繼續待在公園",
    rain_fallback_greeting: greeting,
  });
  const invalid = result([{ character_id: id1, placement: "modern_map", variants: variants(invalidBlocks) }]);
  if (invalid.ok || !invalid.errors.some((error) => error.includes("rain_fallback_invalid"))) throw new Error("outdoor fallback accepted");
});

Deno.test("accepts optional special holiday schedules with existing slot contract", () => {
  const parsed = result([{
    character_id: id1, placement: "modern_map", variants: variants(),
    special_events: [specialEvent("christmas"), specialEvent("valentines_day"), specialEvent("lunar_new_year"), specialEvent("taiwan_public_holiday")],
  }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].special_events.length !== 4) throw new Error("special event schedules were dropped");
  const noEvent = result([{ character_id: id1, placement: "modern_map", variants: variants() }]);
  if (!noEvent.ok || noEvent.characters[0].special_events.length !== 0) throw new Error("special events should remain optional");
});

Deno.test("rejects unknown, duplicate, or malformed special event schedules", () => {
  const unknown = result([{ character_id: id1, placement: "modern_map", variants: variants(), special_events: [specialEvent("birthday")] }]);
  if (unknown.ok || !unknown.errors.some((error) => error.includes("special_event_shape_invalid"))) throw new Error("unknown special event accepted");
  const duplicate = result([{ character_id: id1, placement: "modern_map", variants: variants(), special_events: [specialEvent("christmas"), specialEvent("christmas")] }]);
  if (duplicate.ok || !duplicate.errors.some((error) => error.includes("special_event_duplicate"))) throw new Error("duplicate special event accepted");
});

Deno.test("does not invent birthdays or special events for unplaced characters", () => {
  const built = buildEncounterScheduleBatchMessages([source()]);
  if (!built.messages[0].content.includes("lunar_new_year")) throw new Error("prompt must describe Lunar New Year schedules");
  if (!built.messages[0].content.includes("角色生日目前沒有結構化日期來源")) throw new Error("prompt must not infer character birthdays");
  const unplaced = parseEncounterScheduleBatchOutput(JSON.stringify({
    characters: [{
      character_id: id1, placement: "no_matching_location",
      variants: { weekday: [], holiday: [] }, special_events: [specialEvent("christmas")],
    }],
  }), [source()]);
  if (unplaced.ok || !unplaced.errors.some((error) => error.includes("no_location_variants_must_be_empty"))) throw new Error("unplaced character special events accepted");
});

Deno.test("does not place historical or incompatible fantasy characters on the modern map", () => {
  const ancient = source(id1, { world_era: "ancient", modern_setting_compatible: false });
  if (isEncounterModernMapCompatible(ancient)) throw new Error("ancient role incorrectly marked modern-compatible");
  const ancientResult = parseEncounterScheduleBatchOutput(JSON.stringify({
    characters: [{ character_id: id1, placement: "no_matching_location", variants: { weekday: [], holiday: [] } }],
  }), [ancient]);
  if (!ancientResult.ok) throw new Error(ancientResult.errors.join(","));
  const forced = parseEncounterScheduleBatchOutput(JSON.stringify({
    characters: [{ character_id: id1, placement: "modern_map", variants: variants() }],
  }), [ancient]);
  if (forced.ok) throw new Error("ancient role forced onto modern map");
  const fantasy = source(id1, { world_era: "fantasy", modern_setting_compatible: false });
  if (isEncounterModernMapCompatible(fantasy)) throw new Error("incompatible fantasy role incorrectly accepted");
  const modernVampire = source(id1, { world_era: "modern", race: "吸血鬼", modern_setting_compatible: true });
  if (!isEncounterModernMapCompatible(modernVampire)) throw new Error("modern-compatible fantasy race rejected");
});

Deno.test("normalizes similar scene labels to canonical shared locations", () => {
  if (normalizeEncounterSceneKey("酒吧") !== "night-bar") throw new Error("bar alias failed");
  if (normalizeEncounterSceneKey("辦公大樓") !== "commercial") throw new Error("office alias failed");
  if (normalizeEncounterSceneKey("咖啡廳") !== "cafe") throw new Error("cafe alias failed");
  if (normalizeEncounterSceneKey("夜市") !== "night-market") throw new Error("night market alias failed");
  if (normalizeEncounterSceneKey("醫院") !== "hospital") throw new Error("hospital alias failed");
  if (normalizeEncounterSceneKey("圖書館") !== "library") throw new Error("library alias failed");
  if (normalizeEncounterSceneKey("night market") !== "night-market") throw new Error("English night market alias failed");
  if (normalizeEncounterSceneKey("train station") !== "train-station") throw new Error("English train station alias failed");
});

Deno.test("rejects arbitrary model coordinates and invalid per-hour weights", () => {
  const extraBlocks = hourlyBlocks();
  extraBlocks[0].options[0] = { ...extraBlocks[0].options[0], x: 500 };
  const extraField = result([{ character_id: id1, placement: "modern_map", variants: variants(extraBlocks) }]);
  if (extraField.ok) throw new Error("arbitrary coordinates accepted");
  const wrongWeight = hourlyBlocks();
  wrongWeight[0].options[0] = { ...wrongWeight[0].options[0], weight: 75 };
  const weights = result([{ character_id: id1, placement: "modern_map", variants: variants(wrongWeight) }]);
  if (weights.ok || !weights.errors.some((error) => error.includes("option_weights_must_sum_100"))) throw new Error("invalid per-hour weight sum accepted");
});

Deno.test("accepts only distinct, approved, rights-confirmed public characters", () => {
  let duplicateRejected = false;
  try { buildEncounterScheduleBatchMessages([source(id1), source(id1)]); } catch { duplicateRejected = true; }
  if (!duplicateRejected) throw new Error("duplicate character ids accepted");
  let privateRejected = false;
  try { buildEncounterScheduleBatchMessages([source(id1, { visibility: "private" })]); } catch { privateRejected = true; }
  if (!privateRejected) throw new Error("private character accepted");
  let unapprovedRejected = false;
  try { buildEncounterScheduleBatchMessages([source(id1, { review_status: "pending" })]); } catch { unapprovedRejected = true; }
  if (!unapprovedRejected) throw new Error("unapproved character accepted");
});

Deno.test("builds one prompt with per-hour weights and private-context screening values", () => {
  const built = buildEncounterScheduleBatchMessages([source()]);
  if (built.messages.length !== 2 || built.messages[0].role !== "system") throw new Error("batch messages malformed");
  if (!built.messages[0].content.includes("不同時段獨立抽取") ||
      !built.messages[0].content.includes("同一時段所有選項權重總和必須恰好 100")) {
    throw new Error("per-hour weighted option rules missing from prompt");
  }
  if (!Array.isArray(built.protectedContextByCharacter[id1])) throw new Error("private context guard values missing");
});

Deno.test("infers schedule content from character profile and preserves author schedule constraints", () => {
  const built = buildEncounterScheduleBatchMessages([source(id1, {
    title: "夜間急診醫師", schedule_description: "", tags: ["醫師", "夜班"],
    personality_profile: { occupation: "急診醫師", personality: "冷靜細心", interests: ["夜間攝影"] },
  })]);
  const payload = JSON.parse(built.messages[1].content).characters[0];
  if (payload.author_schedule_brief !== "") throw new Error("empty author schedule was not preserved");
  if (payload.title !== "夜間急診醫師" || payload.occupation !== "急診醫師") throw new Error("character identity fields missing");
  if (!payload.tags.includes("夜班") || payload.author_character_profile.interests[0] !== "夜間攝影") throw new Error("author character profile context missing");
  if (!Array.isArray(payload.existing_author_schedules) || payload.existing_author_schedules.length !== 0) throw new Error("empty author schedule list missing");
  const withManualSchedule = buildEncounterScheduleBatchMessages([source(id1, {
    existing_author_schedules: [{
      weekday: 1, day_type: "weekday", start_time: "09:00", end_time: "17:00",
      location_key: "commercial", activity: "作者指定的固定工作時段",
    }],
  })]);
  const manual = JSON.parse(withManualSchedule.messages[1].content).characters[0].existing_author_schedules[0];
  if (manual.location !== "公司" || "location_key" in manual || manual.activity !== "作者指定的固定工作時段") throw new Error("author schedule context leaked a scene key or lost its natural place");
  if (!built.messages[0].content.includes("existing_author_schedules 是作者已保存的固定時段")) throw new Error("author-managed schedule priority missing");
  if (!built.messages[0].content.includes("若 author_schedule_brief 為空")) throw new Error("prompt does not instruct schedule inference");
});

Deno.test("rejects airport as a generic everyday location without character travel or aviation context", () => {
  const airportBlocks = hourlyBlocks();
  airportBlocks[2].options[0] = option({ weight: 100, location_key: "airport", activity: "在機場大廳等候接機，觀察來往旅客。" });
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(airportBlocks) }]);
  if (parsed.ok || !parsed.errors.some((error) => error.includes("airport_location_without_character_context"))) throw new Error("generic airport schedule accepted");
  const aviationRole = source(id1, { occupation: "航空公司地勤人員", title: "機場地勤" });
  const acceptedBlocks = hourlyBlocks();
  acceptedBlocks[2].options[0] = option({ weight: 100, location_key: "airport", activity: "在機場辦理航班報到與旅客服務。" });
  const accepted = result([{ character_id: id1, placement: "modern_map", variants: variants(acceptedBlocks) }], [aviationRole]);
  if (!accepted.ok) throw new Error(accepted.errors.join(","));
});

Deno.test("preserves unmatched natural-language place intent and character-specific arrival description", () => {
  const blocks = hourlyBlocks();
  blocks[3].options[0] = option({
    weight: 80, location_key: "角色私人工作室", activity: "在自己的工作室整理新作品。",
    scene_description: "他推開工作室的門，將剛完成的草稿放在桌上，窗邊的午後光線落在散亂的畫具上。",
  });
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  const chosen = parsed.characters[0].variants.weekday[3].options[0];
  if (chosen.location_key !== null || chosen.location_description !== "角色私人工作室") throw new Error("unmatched natural-language place was not retained");
  if (!chosen.scene_description.includes("午後光線") || !chosen.activity.includes("整理新作品")) throw new Error("scene description or activity was not preserved");
});

Deno.test("preserves canonical scene intent even when the scene is not currently catalogued", () => {
  const blocks = hourlyBlocks();
  blocks[3].options[0] = option({ weight: 80, location_key: "gym", activity: "在健身房進行重量訓練。" });
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].variants.weekday[3].options[0].location_key !== "gym") throw new Error("unavailable gym intent was not preserved");
  const prompt = buildEncounterScheduleBatchMessages([source()]);
  const payload = JSON.parse(prompt.messages[1].content);
  if ("canonical_scene_keys" in payload || "scene_catalog" in payload) throw new Error("AI prompt must not receive scene IDs or scene catalog");
  if (!prompt.messages[0].content.includes("地點是否能對應地圖由系統自行判斷") ||
      !prompt.messages[0].content.includes("AI 不得判斷玩家是否能相遇")) throw new Error("prompt does not assign scene and encounterability decisions to the system");
  if (!prompt.messages[0].content.includes("scene_description")) throw new Error("prompt does not require a character-specific scene description");
  if (!prompt.messages[0].content.includes("activity 或 scene_description 必須明確寫出熟睡、睡著、睡覺中等可辨識狀態")) throw new Error("prompt does not make sleeping states explicit for deterministic availability checks");
});

Deno.test("preserves unavailable outdoor scene intent while validating its fixed indoor rain fallback", () => {
  const blocks = hourlyBlocks();
  blocks[3].options[0] = option({
    weight: 80, location_key: "night-market", is_outdoor: true,
    rain_fallback_location_key: "cafe", rain_fallback_activity: "改在咖啡廳用餐",
    rain_fallback_greeting: greeting,
  });
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].variants.weekday[3].options[0].location_key !== "night-market") throw new Error("unavailable outdoor scene intent was dropped");
});

Deno.test("uses existing Live House scene without asking AI to update scene metadata", () => {
  const blocks = hourlyBlocks();
  blocks[3].options[0] = option({ weight: 80, location_key: "live-house", activity: "在 Live House 參與樂團演出與彩排。" });
  const accepted = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (!accepted.ok || accepted.scenes.length !== 0) throw new Error(accepted.errors.join(",") || "existing Live House scene should be reused without AI metadata");
});

Deno.test("builds one schedule prompt for all 37 queued roles without the legacy ten-role cap", () => {
  const sources = Array.from({ length: 37 }, (_, index) =>
    source(`33333333-3333-4333-8333-${String(index + 1).padStart(12, "0")}`)
  );
  const built = buildEncounterScheduleBatchMessages(sources);
  const payload = JSON.parse(built.messages[1].content);
  if (payload.characters.length !== 37) throw new Error("the full 37-role queue was not included in one AI prompt");
});


Deno.test("maps ordinary residences to the permanent 308 Apartment but leaves luxury homes unmatched", () => {
  for (const value of ["308公寓", "308 公寓", "私人公寓", "一般公寓", "普通公寓", "住家", "住所", "租屋處", "套房"]) {
    if (normalizeEncounterSceneKey(value) !== "apartment") throw new Error("ordinary residence was not mapped: " + value);
  }
  for (const value of ["豪宅", "私人豪宅", "高級公寓", "豪華別墅", "penthouse"]) {
    if (normalizeEncounterSceneKey(value) !== null) throw new Error("luxury residence was incorrectly mapped: " + value);
  }
});

Deno.test("marks sleeping scenes unavailable without mistaking wakefulness or insomnia for sleep", () => {
  for (const [activity, scene] of [
    ["熟睡中", ""], ["睡覺", "他縮在被子裡熟睡。"],
    ["在家休息", "他已沉沉睡去，床頭燈仍亮著。"], ["繼續睡覺", "他翻身後又沉沉睡去。"],
  ]) {
    if (resolveEncounterScheduleAvailability(activity, scene) !== "sleeping") throw new Error("sleeping state not detected: " + activity);
  }
  for (const [activity, scene] of [
    ["睡不著", "他望著窗簾縫隙，遲遲沒有睡意。"],
    ["剛睡醒", "他坐在床沿揉揉眼睛。"],
    ["在家休息", "他坐在沙發上翻閱一本書。"],
    ["準備睡覺", "他正在浴室洗漱，還沒有上床。"],
  ]) {
    if (resolveEncounterScheduleAvailability(activity, scene) !== "available") throw new Error("non-sleeping state incorrectly blocked: " + activity);
  }
});
