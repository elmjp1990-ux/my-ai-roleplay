import {
  type EncounterSceneCatalogEntry,
  buildEncounterScheduleBatchMessages,
  isEncounterModernMapCompatible,
  normalizeEncounterSceneKey,
  parseEncounterScheduleBatchOutput,
} from "./encounter-schedule-generation.ts";

const id1 = "11111111-1111-4111-8111-111111111111";
const id2 = "22222222-2222-4222-8222-222222222222";
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
  park: "公園", "night-market": "夜市", gym: "健身房", hospital: "醫院",
  library: "圖書館", "train-station": "火車站",
};
const slot = (extra = {}) => {
  const row = {
    start_time: "09:00", end_time: "17:00", location_key: "commercial",
    activity: "在公司處理工作", scene_description: "他站在會議室窗邊整理文件，神情專注，準備開始今天的工作。",
    is_outdoor: false, rain_fallback_location_key: null,
    rain_fallback_activity: null, rain_fallback_greeting: null,
    encounter_greeting: greeting, ...extra,
  } as Record<string, unknown>;
  const locationKey = String(row.location_key || "");
  const fallbackKey = row.rain_fallback_location_key == null ? null : String(row.rain_fallback_location_key);
  delete row.location_key;
  delete row.rain_fallback_location_key;
  row.location = locationNames[locationKey] || locationKey;
  row.rain_fallback_location = fallbackKey ? (locationNames[fallbackKey] || fallbackKey) : null;
  return row;
};
const fullDaySlots = (workSlot = {}) => [
  slot({ start_time: "00:00", end_time: "08:00", location_key: "apartment", activity: "在家休息" }),
  slot({ start_time: "08:00", end_time: "16:00", ...workSlot }),
  slot({ start_time: "16:00", end_time: "22:00", location_key: "cafe", activity: "在咖啡廳休息" }),
  slot({ start_time: "22:00", end_time: "00:00", location_key: "apartment", activity: "回家休息" }),
];
const variants = (slots = fullDaySlots()) => ({
  weekday: [
    { variant_key: "primary", weight: 80, slots },
    { variant_key: "alternative", weight: 20, slots: fullDaySlots({ location_key: "bookstore", activity: "在書店工作" }) },
  ],
  holiday: [
    { variant_key: "primary", weight: 60, slots: fullDaySlots({ start_time: "08:00", end_time: "16:00", location_key: "park", activity: "在公園散步", is_outdoor: true, rain_fallback_location_key: "cafe", rain_fallback_activity: "改在咖啡廳休息", rain_fallback_greeting: greeting }) },
    { variant_key: "alternative", weight: 40, slots: fullDaySlots({ start_time: "08:00", end_time: "16:00", location_key: "department-store", activity: "逛百貨公司" }) },
  ],
});
const builtInSceneCatalog: EncounterSceneCatalogEntry[] = [
  "airport", "commercial", "night-bar", "live-house", "apartment",
  "department-store", "bookstore", "cafe", "park",
].map((location_key) => ({ location_key, display_name: location_key, is_dynamic: false }));
const result = (
  characters: Array<{ character_id: string; [key: string]: unknown }>,
  sourceRows?: ReturnType<typeof source>[],
  sceneCatalog?: EncounterSceneCatalogEntry[],
) => {
  const normalized = characters.map(withGreetingPools);
  return parseEncounterScheduleBatchOutput(
    JSON.stringify({ characters: normalized, scenes: [] }),
    sourceRows ?? characters.map((c) => source(c.character_id)),
    [...builtInSceneCatalog, ...(sceneCatalog ?? [])],
  );
};
const specialEvent = (event_key = "christmas", slots = fullDaySlots()) => ({
  event_key, event_name: ({
    taiwan_public_holiday: "國定假日",
    lunar_new_year: "春節",
    valentines_day: "情人節",
    christmas: "聖誕節",
  } as Record<string, string>)[event_key] ?? "節日", slots,
});


Deno.test("accepts hourly schedules with exact weekday/holiday weights and 8-hour continuous work", () => {
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants() }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].variants.weekday[0].slots[1].end_time !== "16:00") throw new Error("8-hour slot changed");
});

Deno.test("requires 3-5 distinct greetings for all eight relationship stages", () => {
  const accepted = result([{ character_id: id1, placement: "modern_map", variants: variants() }]);
  if (!accepted.ok) throw new Error(accepted.errors.join(","));
  if (Object.keys(accepted.characters[0].relationship_greetings ?? {}).length !== 8) {
    throw new Error("eight relationship-stage greeting pools were not retained");
  }
  const missingStage = relationshipGreetings();
  delete (missingStage as Record<string, unknown>).special;
  const missing = result([{
    character_id: id1, placement: "modern_map", variants: variants(), relationship_greetings: missingStage,
  }]);
  if (missing.ok || !missing.errors.some((error) => error.includes("relationship_greeting_stages_invalid"))) {
    throw new Error("missing relationship stage accepted");
  }
  const tooFew = relationshipGreetings();
  tooFew.close = [greeting, greeting + "第二版"];
  const shortPool = result([{
    character_id: id1, placement: "modern_map", variants: variants(), relationship_greetings: tooFew,
  }]);
  if (shortPool.ok || !shortPool.errors.some((error) => error.includes("greeting_pool_count_invalid"))) {
    throw new Error("two-greeting pool accepted");
  }
  const duplicate = relationshipGreetings();
  duplicate.intimate = [greeting, greeting, greeting + "第三版"];
  const duplicates = result([{
    character_id: id1, placement: "modern_map", variants: variants(), relationship_greetings: duplicate,
  }]);
  if (duplicates.ok || !duplicates.errors.some((error) => error.includes("greeting_pool_duplicate"))) {
    throw new Error("duplicate greeting accepted");
  }
  const short = relationshipGreetings();
  short.hostile = ["太短", greeting + "第二版", greeting + "第三版"];
  const shortGreeting = result([{
    character_id: id1, placement: "modern_map", variants: variants(), relationship_greetings: short,
  }]);
  if (shortGreeting.ok || !shortGreeting.errors.some((error) => error.includes("greeting_pool_length_invalid"))) {
    throw new Error("short relationship greeting accepted");
  }
});

Deno.test("requires 150-300 character scene-aware greeting per schedule slot", () => {
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(fullDaySlots({ encounter_greeting: "太短" })) }]);
  if (parsed.ok || !parsed.errors.some((error) => error.includes("greeting_length_invalid"))) throw new Error("short greeting accepted");
});

Deno.test("rejects overlapping or non-hourly schedule intervals", () => {
  const overlap = result([{
    character_id: id1, placement: "modern_map",
    variants: variants(fullDaySlots({ start_time: "07:00", end_time: "16:00" })),
  }]);
  if (overlap.ok || !overlap.errors.some((error) => error.includes("slots_overlap"))) throw new Error("overlap accepted");
  const nonHourly = result([{
    character_id: id1, placement: "modern_map",
    variants: variants(fullDaySlots({ start_time: "08:30" })),
  }]);
  if (nonHourly.ok || !nonHourly.errors.some((error) => error.includes("time_or_location_invalid"))) throw new Error("non-hour interval accepted");
  const adjacent = result([{
    character_id: id1, placement: "modern_map",
    variants: variants([slot({ start_time: "00:00", end_time: "08:00", location_key: "apartment", activity: "在家休息" }), slot({ start_time: "08:00", end_time: "12:00", location_key: "commercial", activity: "在公司處理工作" }), slot({ start_time: "12:00", end_time: "16:00", location_key: "commercial", activity: "在公司處理工作" }), slot({ start_time: "16:00", end_time: "00:00", location_key: "apartment", activity: "回家休息" })]),
  }]);
  if (adjacent.ok || !adjacent.errors.some((error) => error.includes("should_merge"))) throw new Error("contiguous identical work blocks were not required to merge");
});

Deno.test("allows gaps because omitted periods mean the character is not encounterable", () => {
  const partial = fullDaySlots();
  partial[1] = slot({ start_time: "09:00", end_time: "16:00" });
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(partial) }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].variants.weekday[0].slots[1].start_time !== "09:00") {
    throw new Error("encounterable window was not preserved");
  }
});

Deno.test("requires indoor fallback for outdoor schedules", () => {
  const valid = result([{
    character_id: id1, placement: "modern_map",
    variants: variants(fullDaySlots({
      location_key: "park", is_outdoor: true,
      rain_fallback_location_key: "cafe", rain_fallback_activity: "改在咖啡廳休息", rain_fallback_greeting: greeting,
    })),
  }]);
  if (!valid.ok) throw new Error(valid.errors.join(","));
  const invalid = result([{
    character_id: id1, placement: "modern_map",
    variants: variants(fullDaySlots({
      location_key: "park", is_outdoor: true,
      rain_fallback_location_key: "park", rain_fallback_activity: "繼續待在公園", rain_fallback_greeting: greeting,
    })),
  }]);
  if (invalid.ok || !invalid.errors.some((error) => error.includes("rain_fallback_invalid"))) throw new Error("outdoor fallback accepted");
});

Deno.test("accepts optional special holiday schedules with a complete day", () => {
  const parsed = result([{
    character_id: id1, placement: "modern_map", variants: variants(),
    special_events: [specialEvent("christmas"), specialEvent("valentines_day"), specialEvent("lunar_new_year"), specialEvent("taiwan_public_holiday")],
  }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].special_events.length !== 4) throw new Error("special event schedules were dropped");
  const noEvent = result([{ character_id: id1, placement: "modern_map", variants: variants() }]);
  if (!noEvent.ok || noEvent.characters[0].special_events.length !== 0) {
    throw new Error("special events should remain optional");
  }
});

Deno.test("rejects unknown, duplicate, or incomplete special event schedules", () => {
  const unknown = result([{
    character_id: id1, placement: "modern_map", variants: variants(),
    special_events: [specialEvent("birthday")],
  }]);
  if (unknown.ok || !unknown.errors.some((error) => error.includes("special_event_shape_invalid"))) {
    throw new Error("unknown special event accepted");
  }
  const duplicate = result([{
    character_id: id1, placement: "modern_map", variants: variants(),
    special_events: [specialEvent("christmas"), specialEvent("christmas")],
  }]);
  if (duplicate.ok || !duplicate.errors.some((error) => error.includes("special_event_duplicate"))) {
    throw new Error("duplicate special event accepted");
  }
  const incomplete = fullDaySlots();
  incomplete[1] = slot({ start_time: "09:00", end_time: "16:00" });
  const gap = result([{
    character_id: id1, placement: "modern_map", variants: variants(),
    special_events: [specialEvent("christmas", incomplete)],
  }]);
  if (!gap.ok) throw new Error(gap.errors.join(","));

});

Deno.test("does not invent birthdays or special events for unplaced characters", () => {
  const built = buildEncounterScheduleBatchMessages([source()]);
  if (!built.messages[0].content.includes("lunar_new_year")) {
    throw new Error("prompt must describe Lunar New Year schedules");
  }
  if (!built.messages[0].content.includes("角色生日目前沒有結構化日期來源")) {
    throw new Error("prompt must not infer character birthdays");
  }
  const unplaced = parseEncounterScheduleBatchOutput(JSON.stringify({
    characters: [{
      character_id: id1, placement: "no_matching_location",
      variants: { weekday: [], holiday: [] }, special_events: [specialEvent("christmas")],
    }],
  }), [source()]);
  if (unplaced.ok || !unplaced.errors.some((error) => error.includes("no_location_variants_must_be_empty"))) {
    throw new Error("unplaced character special events accepted");
  }
});

Deno.test("does not place historical or incompatible fantasy characters on the modern map", () => {
  const ancient = source(id1, { world_era: "ancient", modern_setting_compatible: false });
  if (isEncounterModernMapCompatible(ancient)) throw new Error("ancient role incorrectly marked modern-compatible");
  const ancientResult = parseEncounterScheduleBatchOutput(JSON.stringify({
    characters: [{ character_id: id1, placement: "no_matching_location", variants: { weekday: [], holiday: [] } }],
  }), [ancient]);
  if (!ancientResult.ok) throw new Error(ancientResult.errors.join(","));
  const noSceneModern = parseEncounterScheduleBatchOutput(JSON.stringify({
    characters: [{ character_id: id1, placement: "no_matching_location", variants: { weekday: [], holiday: [] } }],
  }), [source()]);
  if (!noSceneModern.ok) throw new Error("modern character without a suitable location should remain unplaced");
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


Deno.test("rejects arbitrary model coordinates and invalid variant weights", () => {
  const extraField = result([{
    character_id: id1, placement: "modern_map",
    variants: variants(fullDaySlots({ x: 500 })),
  }]);
  if (extraField.ok) throw new Error("arbitrary coordinates accepted");
  const wrongWeight = variants();
  wrongWeight.weekday[0].weight = 75;
  const weights = result([{ character_id: id1, placement: "modern_map", variants: wrongWeight }]);
  if (weights.ok || !weights.errors.some((error) => error.includes("variant_contract_invalid"))) {
    throw new Error("wrong variant weight accepted");
  }
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

Deno.test("builds one batch prompt and retains private-context screening values per character", () => {
  const built = buildEncounterScheduleBatchMessages([source()]);
  if (built.messages.length !== 2 || built.messages[0].role !== "system") throw new Error("batch messages malformed");
  if (!built.messages[0].content.includes("primary=80") || !built.messages[0].content.includes("primary=60")) {
    throw new Error("variant weights missing from prompt");
  }
  if (!Array.isArray(built.protectedContextByCharacter[id1])) throw new Error("private context guard values missing");
});

Deno.test("infers a complete schedule from the character profile when the author provides no schedule text", () => {
  const built = buildEncounterScheduleBatchMessages([source(id1, {
    title: "夜間急診醫師",
    schedule_description: "",
    tags: ["醫師", "夜班"],
    personality_profile: { occupation: "急診醫師", personality: "冷靜細心", interests: ["夜間攝影"] },
  })]);
  const payload = JSON.parse(built.messages[1].content).characters[0];
  if (payload.author_schedule_brief !== "") throw new Error("empty author schedule was not preserved as empty");
  if (payload.title !== "夜間急診醫師" || payload.occupation !== "急診醫師") throw new Error("character identity fields missing");
  if (!payload.tags.includes("夜班") || payload.author_character_profile.interests[0] !== "夜間攝影") {
    throw new Error("author character profile context missing");
  }
  if (!Array.isArray(payload.existing_author_schedules) || payload.existing_author_schedules.length !== 0) {
    throw new Error("empty author schedule list missing");
  }
  const withManualSchedule = buildEncounterScheduleBatchMessages([source(id1, {
    existing_author_schedules: [{
      weekday: 1, day_type: "weekday", start_time: "09:00", end_time: "17:00",
      location_key: "commercial", activity: "作者指定的固定工作時段",
    }],
  })]);
  const manual = JSON.parse(withManualSchedule.messages[1].content).characters[0].existing_author_schedules[0];
  if (manual.location !== "公司" || "location_key" in manual ||
      manual.activity !== "作者指定的固定工作時段") {
    throw new Error("author schedule context leaked a scene key or lost its natural place");
  }
  if (!built.messages[0].content.includes("existing_author_schedules 是作者已保存的固定時段")) {
    throw new Error("author-managed schedule priority missing");
  }
  if (!built.messages[0].content.includes("若 author_schedule_brief 為空")) {
    throw new Error("prompt does not instruct inference when schedule text is absent");
  }
});

Deno.test("rejects airport as a generic everyday location without character travel or aviation context", () => {
  const airportSchedules = variants(fullDaySlots({
    location_key: "airport",
    activity: "在機場大廳等候接機，觀察來往旅客。",
  }));
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: airportSchedules }]);
  if (parsed.ok || !parsed.errors.some((error) => error.includes("airport_location_without_character_context"))) {
    throw new Error("generic airport schedule accepted");
  }
  const aviationRole = source(id1, { occupation: "航空公司地勤人員", title: "機場地勤" });
  const accepted = result([{
    character_id: id1, placement: "modern_map", variants: variants(fullDaySlots({
      location_key: "airport", activity: "在機場辦理航班報到與旅客服務。",
    })),
  }], [aviationRole]);
  if (!accepted.ok) throw new Error(accepted.errors.join(","));
});

Deno.test("preserves unmatched natural-language place intent and character-specific arrival description", () => {
  const candidate = {
    character_id: id1, placement: "modern_map",
    variants: variants(fullDaySlots({
      location_key: "角色私人工作室",
      activity: "在自己的工作室整理新作品。",
      scene_description: "他推開工作室的門，將剛完成的草稿放在桌上，窗邊的午後光線落在散亂的畫具上。",
    })),
  };
  const parsed = result([candidate]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  const slot = parsed.characters[0].variants.weekday[0].slots[1];
  if (slot.location_key !== null || slot.location_description !== "角色私人工作室") {
    throw new Error("unmatched natural-language place was not retained independently from the map key");
  }
  if (!slot.scene_description.includes("午後光線") || !slot.activity.includes("整理新作品")) {
    throw new Error("arrival scene description or activity was not preserved");
  }
});

Deno.test("preserves canonical scene intent even when the scene is not currently catalogued", () => {
  const candidate = {
    character_id: id1, placement: "modern_map",
    variants: variants(fullDaySlots({ location_key: "gym", activity: "在健身房進行重量訓練。" })),
  };
  const parsed = result([candidate]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].variants.weekday[0].slots[1].location_key !== "gym") {
    throw new Error("unavailable gym intent was not preserved");
  }
  const prompt = buildEncounterScheduleBatchMessages([source()]);
  const payload = JSON.parse(prompt.messages[1].content);
  if ("canonical_scene_keys" in payload || "scene_catalog" in payload) {
    throw new Error("AI prompt must not receive scene IDs or scene catalog");
  }
  if (!prompt.messages[0].content.includes("地點是否能對應地圖由系統自行判斷") ||
      !prompt.messages[0].content.includes("AI 不得判斷玩家是否能相遇")) {
    throw new Error("prompt does not assign scene and encounterability decisions to the system");
  }
  if (!prompt.messages[0].content.includes("scene_description")) {
    throw new Error("prompt does not require a character-specific scene description");
  }
});

Deno.test("preserves unavailable outdoor scene intent while validating its fixed indoor rain fallback", () => {
  const candidate = {
    character_id: id1, placement: "modern_map",
    variants: variants(fullDaySlots({
      location_key: "night-market", is_outdoor: true,
      rain_fallback_location_key: "cafe", rain_fallback_activity: "改在咖啡廳用餐",
      rain_fallback_greeting: greeting,
    })),
  };
  const parsed = result([candidate]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].variants.weekday[0].slots[1].location_key !== "night-market") {
    throw new Error("unavailable outdoor scene intent was dropped");
  }
});

Deno.test("uses existing Live House scene without asking AI to update scene metadata", () => {
  const character = {
    character_id: id1, placement: "modern_map",
    variants: variants(fullDaySlots({
      location_key: "live-house",
      activity: "在 Live House 參與樂團演出與彩排。",
    })),
  };
  const accepted = result([character]);
  if (!accepted.ok || accepted.scenes.length !== 0) {
    throw new Error(accepted.errors.join(",") || "existing Live House scene should be reused without AI metadata");
  }
});


Deno.test("builds one schedule prompt for all 37 queued roles without the legacy ten-role cap", () => {
  const sources = Array.from({ length: 37 }, (_, index) =>
    source(`33333333-3333-4333-8333-${String(index + 1).padStart(12, "0")}`)
  );
  const built = buildEncounterScheduleBatchMessages(sources);
  const payload = JSON.parse(built.messages[1].content);
  if (payload.characters.length !== 37) {
    throw new Error("the full 37-role queue was not included in one AI prompt");
  }
});
