import {
  type EncounterSceneCatalogEntry,
  buildEncounterScheduleBatchMessages,
  classifyEncounterWorldview,
  getEncounterWorldviewScheduleDisposition,
  isEncounterModernMapCompatible,
  normalizeEncounterSceneKey,
  classifyEncounterActivitySpace,
  resolveEncounterScheduleAvailability,
  parseEncounterScheduleBatchOutput,
} from "./encounter-schedule-generation.ts";

const id1 = "11111111-1111-4111-8111-111111111111";
const author = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const source = (character_id = id1, extra = {}) => ({
  character_id, author_id: author, visibility: "public", review_status: "approved", rights_confirmed: true, deleted_at: null,
  name: "測試角色", intro: "現代城市生活",
  world_era: "modern", modern_setting_compatible: true, time_travel_explicit: false,
  schedule_description: "白天在公司工作，晚上和朋友見面",
  private_info: "只供角色一致性使用的私密設定", personality_profile: { tone: "溫柔" },
  ...extra,
});
const locations: Record<string, string> = {
  apartment: "公寓", commercial: "公司", cafe: "咖啡廳", park: "公園",
  "music-studio": "音樂工作室", restaurant: "餐廳", "art-gallery": "藝廊",
};
const option = (extra: Record<string, unknown> = {}) => ({
  weight: 100,
  location: "公司",
  activity: "在辦公室整理今天的工作資料",
  is_outdoor: false,
  rain_fallback_location: null,
  rain_fallback_activity: null,
  ...extra,
});
const block = (hour: number, options?: Record<string, unknown>[]) => ({
  start_time: String(hour).padStart(2, "0") + ":00",
  end_time: String((hour + 1) % 24).padStart(2, "0") + ":00",
  options: options ?? [
    option({ weight: 60 }),
    option({ weight: 40, activity: "在辦公室檢查待辦並回覆客戶訊息" }),
  ],
});
const hourlyBlocks = () => Array.from({ length: 24 }, (_, hour) => {
  if (hour < 8) return block(hour, [
    option({ weight: 80, location: "公寓", activity: "在公寓裡熟睡，房間保持安靜" }),
    option({ weight: 20, location: "公寓", activity: "醒來喝水後又躺回床上休息" }),
  ]);
  if (hour === 17) return block(hour, [
    option({
      weight: 75, location: "公園", activity: "沿著公園步道散步並聽音樂",
      is_outdoor: true, rain_fallback_location: "咖啡廳", rain_fallback_activity: "改到咖啡廳坐著聽音樂",
    }),
    option({ weight: 25, location: "公寓", activity: "留在家中整理房間與生活用品" }),
  ]);
  return block(hour);
});
const variants = (weekday = hourlyBlocks()) => ({
  weekday,
  holiday: hourlyBlocks(),
});
const builtInSceneCatalog: EncounterSceneCatalogEntry[] = [
  { location_key: "commercial", display_name: "公司", is_dynamic: false },
  { location_key: "cafe", display_name: "咖啡廳", is_dynamic: false },
  { location_key: "art-gallery", display_name: "私人畫室", is_dynamic: true },
];
const result = (
  characters: Array<{ character_id: string; [key: string]: unknown }>,
  sourceRows?: ReturnType<typeof source>[],
  sceneCatalog?: EncounterSceneCatalogEntry[],
) => parseEncounterScheduleBatchOutput(
  JSON.stringify({ characters, scenes: [] }),
  sourceRows ?? characters.map((c) => source(c.character_id)),
  [...builtInSceneCatalog, ...(sceneCatalog ?? [])],
);

Deno.test("accepts full weekday and holiday days with independent weighted options", () => {
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants() }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  const weekday = parsed.characters[0].variants.weekday;
  const holiday = parsed.characters[0].variants.holiday;
  if (weekday.length !== 24 || holiday.length !== 24) throw new Error("both date types must contain exactly 24 hours");
  if (weekday[0].start_time !== "00:00" || weekday[23].end_time !== "00:00") throw new Error("day boundaries were not retained");
  if (weekday[0].options.length !== 2 || weekday[0].options[0].weight !== 80 || weekday[0].options[1].weight !== 20) {
    throw new Error("per-hour weights were not retained");
  }
  if (weekday[17].options[0].rain_fallback_greeting !== null || weekday[17].options[0].encounter_greeting !== null) {
    throw new Error("legacy greeting columns must be empty; greetings are generated during the encounter turn");
  }
});


Deno.test("accepts descriptive venue labels such as 歸途（酒吧）", () => {
  const blocks = hourlyBlocks();
  blocks[18] = block(18, [
    option({ weight: 60, location: "歸途（酒吧）", activity: "在酒吧吧台調製雞尾酒並招呼熟客" }),
    option({ weight: 40, location: "歸途（酒吧）", activity: "在酒館角落整理酒單並準備營業" }),
  ]);
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].variants.weekday[18].options[0].location_description !== "歸途（酒吧）") {
    throw new Error("descriptive venue label was not preserved");
  }
});

Deno.test("rejects missing hours, gaps, and non-hourly blocks", () => {
  const missing = hourlyBlocks().slice(0, 23);
  const missingResult = result([{ character_id: id1, placement: "modern_map", variants: variants(missing) }]);
  if (missingResult.ok || !missingResult.errors.some((error) => error.includes("must_cover_24_hours"))) throw new Error("23-hour day accepted");
  const gap = hourlyBlocks();
  gap[12] = { ...gap[12], start_time: "13:00", end_time: "14:00" };
  const gapResult = result([{ character_id: id1, placement: "modern_map", variants: variants(gap) }]);
  if (gapResult.ok || !gapResult.errors.some((error) => error.includes("contiguous_24_hour_day"))) throw new Error("hour gap accepted");
  const nonHourly = hourlyBlocks();
  nonHourly[0] = { ...nonHourly[0], start_time: "00:30", end_time: "01:30" };
  const nonHourlyResult = result([{ character_id: id1, placement: "modern_map", variants: variants(nonHourly) }]);
  if (nonHourlyResult.ok) throw new Error("non-hour interval accepted");
});

Deno.test("requires at least two options in every hourly block", () => {
  const blocks = hourlyBlocks();
  blocks[12] = block(12, [option()]);
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (parsed.ok || !parsed.errors.some((error) => error.includes("options_count_invalid"))) {
    throw new Error("hourly block with only one option accepted");
  }
});

Deno.test("requires 2-3 options and exact 100 percent weight totals per hour", () => {
  const tooFew = hourlyBlocks();
  tooFew[0] = block(0, [option()]);
  const tooFewResult = result([{ character_id: id1, placement: "modern_map", variants: variants(tooFew) }]);
  if (tooFewResult.ok || !tooFewResult.errors.some((error) => error.includes("options_count_invalid"))) {
    throw new Error("one option accepted");
  }
  const tooMany = hourlyBlocks();
  tooMany[0] = block(0, [option({ weight: 34 }), option({ weight: 33 }), option({ weight: 33 }), option()]);
  const tooManyResult = result([{ character_id: id1, placement: "modern_map", variants: variants(tooMany) }]);
  if (tooManyResult.ok) throw new Error("four options accepted");
  const wrongWeight = hourlyBlocks();
  wrongWeight[0] = block(0, [option({ weight: 75 }), option({ weight: 20 })]);
  const weightResult = result([{ character_id: id1, placement: "modern_map", variants: variants(wrongWeight) }]);
  if (weightResult.ok || !weightResult.errors.some((error) => error.includes("option_weights_must_sum_100"))) {
    throw new Error("invalid weight total accepted");
  }
});

Deno.test("limits activity descriptions to 10-30 characters and rejects extra greeting fields", () => {
  const short = hourlyBlocks();
  short[0] = block(0, [option({ activity: "睡覺" }), option({ weight: 0, activity: "醒來喝水後又躺回床上休息" })]);
  const shortResult = result([{ character_id: id1, placement: "modern_map", variants: variants(short) }]);
  if (shortResult.ok || !shortResult.errors.some((error) => error.includes("activity_length_invalid"))) throw new Error("short activity accepted");
  const extra = hourlyBlocks();
  extra[0] = block(0, [option({ encounter_greeting: "不應由行程 AI 產生的招呼" }), option({ weight: 0 })]);
  const extraResult = result([{ character_id: id1, placement: "modern_map", variants: variants(extra) }]);
  if (extraResult.ok || !extraResult.errors.some((error) => error.includes("option_0_keys_invalid"))) throw new Error("generated greeting field accepted");
});

Deno.test("requires an indoor rain fallback for outdoor options only", () => {
  const valid = result([{ character_id: id1, placement: "modern_map", variants: variants() }]);
  if (!valid.ok) throw new Error(valid.errors.join(","));
  const invalid = hourlyBlocks();
  invalid[17] = block(17, [option({
    weight: 75, location: "公園", activity: "沿著公園步道散步並聽音樂",
    is_outdoor: true, rain_fallback_location: "公園", rain_fallback_activity: "下雨時仍在公園散步",
  }), option({ weight: 25 })]);
  const invalidResult = result([{ character_id: id1, placement: "modern_map", variants: variants(invalid) }]);
  if (invalidResult.ok || !invalidResult.errors.some((error) => error.includes("rain_fallback_invalid"))) {
    throw new Error("outdoor rain fallback to another outdoor scene accepted");
  }
  const unexpected = hourlyBlocks();
  unexpected[1] = block(1, [
    option({ weight: 60, rain_fallback_location: "公寓", rain_fallback_activity: "改在家裡整理房間" }),
    option({ weight: 40 }),
  ]);
  const unexpectedResult = result([{ character_id: id1, placement: "modern_map", variants: variants(unexpected) }]);
  if (unexpectedResult.ok || !unexpectedResult.errors.some((error) => error.includes("unexpected_rain_fallback"))) {
    throw new Error("indoor option with rain fallback accepted");
  }
});

Deno.test("classifies activity space independently from scene location", () => {
  const cases: Array<[string, string, boolean, string]> = [
    ["在公寓陽台抽菸，望著夜景發呆", "住所", true, "indoor"],
    ["前往客戶住處修理電燈與組裝書架", "客戶家", true, "indoor"],
    ["在餐廳包廂陪客戶出席晚宴", "餐廳", true, "indoor"],
    ["在超商貨架前挑選飲料並結帳", "超商", true, "indoor"],
    ["晚宴結束後在計程車內送客戶回家", "街頭", true, "vehicle"],
    ["下車後在街頭向客戶道別", "街頭", false, "outdoor"],
    ["站在騎樓下抽菸放空", "街頭", false, "outdoor"],
    ["在舊公寓臥室熟睡，窗外的街道寂靜無聲", "住所", false, "indoor"],
    ["在街頭咖啡店內用餐", "街頭", true, "indoor"],
    ["在餐廳門口等客戶下車", "餐廳", false, "outdoor"],
  ];
  for (const [activity, location, requestedOutdoor, expected] of cases) {
    const actual = classifyEncounterActivitySpace(activity, location, requestedOutdoor);
    if (actual !== expected) throw new Error(activity + " classified as " + actual + " instead of " + expected);
  }
  if (normalizeEncounterSceneKey("客戶家") !== "apartment") throw new Error("customer home must resolve to the apartment scene");
  if (normalizeEncounterSceneKey("街頭") !== "shopping-street") throw new Error("street must resolve to the existing street scene family");
  if (normalizeEncounterSceneKey("超商") !== "shopping-street") throw new Error("convenience store must retain a valid shopping-district scene key");
  if (normalizeEncounterSceneKey("小吃店") !== "restaurant") throw new Error("small eatery must resolve to restaurant");
});

Deno.test("keeps free natural-language locations and applies system scene matching", () => {
  const blocks = hourlyBlocks();
  blocks[8] = block(8, [
    option({ weight: 60, location: "私人畫室", activity: "在私人畫室整理畫具並完成草稿" }),
    option({ weight: 40 }),
  ]);
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].variants.weekday[8].options[0].location_description !== "私人畫室" ||
      parsed.characters[0].variants.weekday[8].options[0].location_key !== "art-gallery") {
    throw new Error("custom natural location was not preserved and system-matched");
  }
  if (normalizeEncounterSceneKey("酒吧") !== "night-bar" ||
      normalizeEncounterSceneKey("辦公大樓") !== "commercial" ||
      normalizeEncounterSceneKey("咖啡廳") !== "cafe" ||
      normalizeEncounterSceneKey("展演廳") !== "live-house" ||
      normalizeEncounterSceneKey("代辦所") !== "commercial") throw new Error("canonical scene aliases regressed");

  const tooLong = hourlyBlocks();
  tooLong[8] = block(8, [option({ weight: 60, location: "音樂工作室" }), option({ weight: 40 })]);
  const rejected = result([{ character_id: id1, placement: "modern_map", variants: variants(tooLong) }]);
  if (rejected.ok || !rejected.errors.some((error) => error.includes("location_invalid"))) {
    throw new Error("location label longer than four characters accepted");
  }
});

Deno.test("preserves modern schedules when the model reports no matching map location", () => {
  const parsed = result([{ character_id: id1, placement: "no_matching_location", variants: variants() }]);
  if (!parsed.ok || parsed.characters[0].placement !== "modern_map" ||
      parsed.characters[0].variants.weekday.length !== 24) {
    throw new Error("modern natural-language schedule was discarded");
  }
});

Deno.test("infers modern map compatibility from contemporary character context", () => {
  const wealthyModernRole = source(id1, {
    name: "沈若薇",
    intro: "頂尖財閥沈氏集團的掌上明珠，也是總裁夫人，經常出席慈善晚宴與藝術展覽。",
    world_era: "頂尖財閥沈氏集團的掌上明珠，也是總裁夫人",
    modern_setting_compatible: false,
    schedule_description: "平日穿梭於慈善晚宴、藝術展覽與集團社交場合。",
  });
  if (!isEncounterModernMapCompatible(wealthyModernRole)) {
    throw new Error("contemporary finance and corporate setting incorrectly marked incompatible");
  }
  const built = buildEncounterScheduleBatchMessages([wealthyModernRole]);
  const payload = JSON.parse(built.messages[1].content).characters[0];
  if (payload.modern_setting_compatible !== true) {
    throw new Error("derived modern compatibility was not sent to the model");
  }
});

Deno.test("classifies worldviews locally and keeps species separate from era", () => {
  const modernVampire = source(id1, {
    race: "吸血鬼",
    intro: "居住在現代台北的吸血鬼，白天經營私人畫廊，晚上出席藝術活動。",
    world_era: "現代都市",
  });
  const vampireClass = classifyEncounterWorldview(modernVampire);
  if (vampireClass.category !== "modern_fantasy" || !vampireClass.modern_map_compatible) {
    throw new Error("modern vampire should be modern-fantasy and map compatible");
  }

  const ancientVampire = source(id1, {
    race: "吸血鬼",
    intro: "中世紀古堡中的吸血鬼伯爵。",
    world_era: "medieval",
  });
  const ancientVampireClass = classifyEncounterWorldview(ancientVampire);
  if (ancientVampireClass.category !== "historical" || ancientVampireClass.modern_map_compatible) {
    throw new Error("medieval vampire should remain historical and off the modern map");
  }

  const cultivation = source(id1, { intro: "修仙宗門中的劍修，正在閉關渡劫。", world_era: "修仙世界" });
  if (classifyEncounterWorldview(cultivation).category !== "cultivation") {
    throw new Error("cultivation worldview was not classified");
  }

  const unknown = source(id1, {
    intro: "一位神秘旅人。", world_era: "", modern_setting_compatible: false,
    schedule_description: "", private_info: "", personality_profile: {},
  });
  const unknownClass = classifyEncounterWorldview(unknown);
  if (unknownClass.category !== "unknown" || unknownClass.modern_map_compatible) {
    throw new Error("unknown worldview must be held out of the modern map");
  }
  if (getEncounterWorldviewScheduleDisposition(unknownClass) !== "needs_review") {
    throw new Error("unknown worldview must enter manual review instead of completed/unplaced");
  }
  if (getEncounterWorldviewScheduleDisposition(unknownClass, "modern_map_compatible") !== "generate") {
    throw new Error("explicit author review decision should authorize modern-map generation");
  }
  const reviewedUnknown = { ...unknown, worldview_review_decision: "modern_map_compatible" };
  if (!isEncounterModernMapCompatible(reviewedUnknown)) {
    throw new Error("manual modern-map approval must be reflected in the generation prompt compatibility flag");
  }
  const reviewedPayload = JSON.parse(buildEncounterScheduleBatchMessages([reviewedUnknown]).messages[1].content).characters[0];
  if (reviewedPayload.modern_setting_compatible !== true) {
    throw new Error("manual modern-map approval was not passed into the AI prompt");
  }
  if (getEncounterWorldviewScheduleDisposition(classifyEncounterWorldview(ancientVampire)) !== "not_applicable") {
    throw new Error("known historical worldview should remain a normal non-modern exclusion");
  }
  if (getEncounterWorldviewScheduleDisposition(vampireClass) !== "generate") {
    throw new Error("modern-compatible worldview should continue to AI generation");
  }

  const alternateWorld = source(id1, {
    intro: "來自異世界的旅人。",
    world_era: "",
    modern_setting_compatible: false,
    time_travel_explicit: false,
    schedule_description: "",
    private_info: "",
    personality_profile: {},
  });
  if (classifyEncounterWorldview(alternateWorld).category !== "alternate_world") {
    throw new Error("異世界 alone should be classified as alternate_world, not generic fantasy");
  }
});

Deno.test("keeps incompatible historical characters off the modern map", () => {
  const ancient = source(id1, { world_era: "ancient", intro: "秦漢時代的古代王朝", schedule_description: "", modern_setting_compatible: false });
  if (isEncounterModernMapCompatible(ancient)) throw new Error("ancient role incorrectly marked modern-compatible");
  const parsed = parseEncounterScheduleBatchOutput(JSON.stringify({
    characters: [{
      character_id: id1, placement: "no_matching_location",
      variants: { weekday: [], holiday: [] }, special_events: [],
    }],
    scenes: [],
  }), [ancient]);
  if (!parsed.ok || parsed.characters[0].variants.weekday.length !== 0) throw new Error(parsed.errors.join(","));
  const forced = result([{ character_id: id1, placement: "modern_map", variants: variants() }], [ancient]);
  if (forced.ok) throw new Error("ancient role forced onto modern map");
});

Deno.test("keeps sleeping detection based on concise activity text", () => {
  if (resolveEncounterScheduleAvailability("正在熟睡") !== "sleeping") throw new Error("sleeping activity not detected");
  if (resolveEncounterScheduleAvailability("在家休息") !== "available") throw new Error("ordinary rest incorrectly blocked");
});

Deno.test("rejects airport as a generic everyday location without character context", () => {
  const blocks = hourlyBlocks();
  blocks[8] = block(8, [
    option({ weight: 60, location: "機場", activity: "在機場辦理航班報到與旅客服務" }),
    option({ weight: 40 }),
  ]);
  const generic = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (generic.ok || !generic.errors.some((error) => error.includes("airport_location_without_character_context"))) {
    throw new Error("generic airport schedule accepted");
  }
  const aviationRole = source(id1, { occupation: "航空公司地勤人員", title: "機場地勤" });
  const accepted = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }], [aviationRole]);
  if (!accepted.ok) throw new Error(accepted.errors.join(","));
});

Deno.test("builds concise schedule prompts without generated greetings", () => {
  const built = buildEncounterScheduleBatchMessages([source()], [
    { location_key: "commercial", display_name: "公司", is_dynamic: false },
    { location_key: "cafe", display_name: "咖啡廳", is_dynamic: false },
  ]);
  const prompt = built.messages[0].content;
  if (built.messages.length !== 2 || !prompt.includes("不同時段獨立抽取") ||
      !prompt.includes("恰好 24 個逐小時時段") ||
      !prompt.includes("10–30 個中文字") ||
      !prompt.includes("每個時段必須提供 2–3 個選項")) {
    throw new Error("24-hour compact schedule rules missing");
  }
  if (prompt.includes("relationship_greetings") || prompt.includes("encounter_greeting") ||
      prompt.includes("rain_fallback_greeting")) throw new Error("greeting generation remains in schedule prompt");
  if (prompt.includes("公司、咖啡廳") || prompt.includes("目前地圖可用地點範例") ||
      prompt.includes("AI 只會看到少量現有場景") ||
      prompt.includes("百貨公司、書店、咖啡廳") ||
      prompt.includes("車站、商業大樓") ||
      !prompt.includes("不得向模型提供任何地圖地點建議")) {
    throw new Error("scene suggestions were passed to the model");
  }
  if (!Array.isArray(built.protectedContextByCharacter[id1])) throw new Error("private context guard values missing");
});

Deno.test("infers schedules from character profile and preserves author constraints", () => {
  const built = buildEncounterScheduleBatchMessages([source(id1, {
    title: "夜間急診醫師", schedule_description: "", tags: ["醫師", "夜班"],
    personality_profile: { occupation: "急診醫師", personality: "冷靜細心", interests: ["夜間攝影"] },
  })]);
  const payload = JSON.parse(built.messages[1].content).characters[0];
  if (payload.author_schedule_brief !== "" || payload.title !== "夜間急診醫師" || payload.occupation !== "急診醫師") {
    throw new Error("character profile context missing");
  }
  if (!payload.tags.includes("夜班") || payload.author_character_profile.interests[0] !== "夜間攝影") {
    throw new Error("author profile interests missing");
  }
  if (!Array.isArray(payload.existing_author_schedules) || payload.existing_author_schedules.length !== 0) {
    throw new Error("existing author schedule context missing");
  }
  if (!built.messages[0].content.includes("existing_author_schedules 是作者已保存的固定時段")) {
    throw new Error("author schedule priority missing");
  }
});

Deno.test("rejects duplicate and non-public character sources", () => {
  let duplicateRejected = false;
  try { buildEncounterScheduleBatchMessages([source(id1), source(id1)]); } catch { duplicateRejected = true; }
  if (!duplicateRejected) throw new Error("duplicate character ids accepted");
  let privateRejected = false;
  try { buildEncounterScheduleBatchMessages([source(id1, { visibility: "private" })]); } catch { privateRejected = true; }
  if (!privateRejected) throw new Error("private character accepted");
});
