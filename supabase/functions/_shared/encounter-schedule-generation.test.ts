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
  apartment: "308公寓", "luxury-apartment": "高級公寓", commercial: "辦公大樓",
  airport: "機場", university: "校園", park: "中央公園",
  "shopping-street": "商店街", "department-store": "百貨公司", hospital: "中央醫院",
  "night-bar": "夜間酒吧", "live-house": "展演空間",
  waterfront: "水岸港區", "convenience-store": "便利商店", "private-club": "高級會所",
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
      is_outdoor: true, rain_fallback_location: "便利商店", rain_fallback_activity: "改到便利商店坐著聽音樂",
    }),
    option({ weight: 25, location: "公寓", activity: "留在家中整理房間與生活用品" }),
  ]);
  return block(hour);
});
const variants = (weekday = hourlyBlocks()) => ({
  weekday,
  holiday: hourlyBlocks(),
});
const builtInSceneCatalog: EncounterSceneCatalogEntry[] = Object.entries(locations)
  .map(([location_key, display_name]) => ({ location_key, display_name, is_dynamic: false }));
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

Deno.test("salvages valid hours when a day has missing, duplicated, or malformed blocks", () => {
  const missing = hourlyBlocks().slice(0, 23);
  const missingResult = result([{ character_id: id1, placement: "modern_map", variants: variants(missing) }]);
  if (!missingResult.ok || !missingResult.characters[0].partial) throw new Error("23 valid hours should be published for review");
  if (missingResult.characters[0].variants.weekday.length !== 23) throw new Error("valid 23-hour subset was not preserved");

  const gap = hourlyBlocks();
  gap[12] = { ...gap[12], start_time: "13:00", end_time: "14:00" };
  const gapResult = result([{ character_id: id1, placement: "modern_map", variants: variants(gap) }]);
  if (!gapResult.ok || !gapResult.characters[0].partial) throw new Error("duplicate hour should be salvaged as a partial day");
  if (gapResult.characters[0].variants.weekday.length !== 23) throw new Error("overlapping hour was not excluded");

  const nonHourly = hourlyBlocks();
  nonHourly[0] = { ...nonHourly[0], start_time: "00:30", end_time: "01:30" };
  const nonHourlyResult = result([{ character_id: id1, placement: "modern_map", variants: variants(nonHourly) }]);
  if (!nonHourlyResult.ok || nonHourlyResult.characters[0].variants.weekday.length !== 23) {
    throw new Error("non-hour interval should be excluded without discarding other hours");
  }
});

Deno.test("salvages a single valid option and normalizes its weight to 100", () => {
  const blocks = hourlyBlocks();
  blocks[12] = block(12, [option({ weight: 40 })]);
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(blocks) }]);
  if (!parsed.ok || !parsed.characters[0].partial) throw new Error("single valid option should be retained for review");
  const saved = parsed.characters[0].variants.weekday[12].options;
  if (saved.length !== 1 || saved[0].weight !== 100) throw new Error("single option weight was not normalized");
});

Deno.test("filters excess options and normalizes valid option weights per hour", () => {
  const tooMany = hourlyBlocks();
  tooMany[0] = block(0, [
    option({ weight: 34 }), option({ weight: 33, activity: "在辦公室檢查待辦並回覆客戶訊息" }),
    option({ weight: 33, activity: "在公司整理資料並確認今天的工作進度" }),
    option({ weight: 10, activity: "在公司整理資料並確認今天的工作進度" }),
  ]);
  const tooManyResult = result([{ character_id: id1, placement: "modern_map", variants: variants(tooMany) }]);
  if (!tooManyResult.ok || !tooManyResult.characters[0].partial) throw new Error("excess option should be excluded");
  const options = tooManyResult.characters[0].variants.weekday[0].options;
  if (options.length !== 3 || options.reduce((sum, item) => sum + item.weight, 0) !== 100) {
    throw new Error("remaining options must be capped and renormalized to 100");
  }

  const wrongWeight = hourlyBlocks();
  wrongWeight[0] = block(0, [option({ weight: 75 }), option({ weight: 20 })]);
  const weightResult = result([{ character_id: id1, placement: "modern_map", variants: variants(wrongWeight) }]);
  if (!weightResult.ok || !weightResult.characters[0].partial) throw new Error("wrong source weights should be normalized");
  if (weightResult.characters[0].variants.weekday[0].options.reduce((sum, item) => sum + item.weight, 0) !== 100) {
    throw new Error("normalized option weights must sum to 100");
  }
});

Deno.test("excludes invalid options while retaining other valid hours", () => {
  const short = hourlyBlocks();
  short[0] = block(0, [
    option({ activity: "睡覺" }),
    option({ weight: 0, activity: "醒來喝水後又躺回床上休息" }),
  ]);
  const shortResult = result([{ character_id: id1, placement: "modern_map", variants: variants(short) }]);
  if (!shortResult.ok || !shortResult.characters[0].partial) throw new Error("invalid options should not discard the whole character");
  if (shortResult.characters[0].variants.weekday.some((item) => item.start_time === "00:00")) {
    throw new Error("an hour with no valid options must be omitted");
  }

  const extra = hourlyBlocks();
  extra[0] = block(0, [
    option({ encounter_greeting: "不應由行程 AI 產生的招呼" }),
    option({ weight: 0 }),
  ]);
  const extraResult = result([{ character_id: id1, placement: "modern_map", variants: variants(extra) }]);
  if (!extraResult.ok || !extraResult.characters[0].partial) throw new Error("invalid extra fields should be excluded");
});

Deno.test("rain fallback fields are optional and unrestricted by scene policy", () => {
  const missingFallback = hourlyBlocks();
  missingFallback[17] = block(17, [
    option({ weight: 75, location: "公園", activity: "沿著公園步道散步並聽音樂", is_outdoor: true }),
    option({ weight: 25 }),
  ]);
  const missingResult = result([{ character_id: id1, placement: "modern_map", variants: variants(missingFallback) }]);
  if (!missingResult.ok) throw new Error(missingResult.errors.join(","));

  const unrestrictedFallback = hourlyBlocks();
  unrestrictedFallback[17] = block(17, [
    option({
      weight: 75, location: "公園", activity: "沿著公園步道散步並聽音樂", is_outdoor: true,
      rain_fallback_location: "河邊露天座位", rain_fallback_activity: "喜歡在雨中繼續散步",
    }),
    option({ weight: 25 }),
  ]);
  const unrestrictedResult = result([{ character_id: id1, placement: "modern_map", variants: variants(unrestrictedFallback) }]);
  if (!unrestrictedResult.ok) throw new Error(unrestrictedResult.errors.join(","));
  const chosen = unrestrictedResult.characters[0].variants.weekday[17].options[0];
  if (chosen.rain_fallback_location_key !== null || chosen.rain_fallback_activity !== "喜歡在雨中繼續散步") {
    throw new Error("unmapped outdoor fallback label should remain optional and accepted");
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
  if (normalizeEncounterSceneKey("客戶家") !== "apartment" ||
      normalizeEncounterSceneKey("客戶家", "前往客戶的高級公寓拜訪") !== "luxury-apartment") {
    throw new Error("customer homes must resolve to L by default and K when luxury context is explicit");
  }
  if (normalizeEncounterSceneKey("街頭") !== "shopping-street") throw new Error("street must resolve to the existing street scene family");
  if (normalizeEncounterSceneKey("便利商店") !== "convenience-store" || normalizeEncounterSceneKey("超商") !== "convenience-store") {
    throw new Error("convenience stores must resolve to fixed scene M");
  }
  if (normalizeEncounterSceneKey("江邊堤防") !== "waterfront") {
    throw new Error("river embankment must resolve to fixed scene A");
  }
  if (normalizeEncounterSceneKey("高級公寓") !== "luxury-apartment" ||
      normalizeEncounterSceneKey("高級會所") !== "private-club" ||
      normalizeEncounterSceneKey("中央醫院") !== "hospital" ||
      normalizeEncounterSceneKey("校園") !== "university") {
    throw new Error("fixed A–N scene destinations must resolve to their canonical keys");
  }
  for (const location of ["308公寓", "頂樓加蓋", "頂樓出租屋", "一般公寓", "臥室", "房間", "住所"]) {
    if (normalizeEncounterSceneKey(location) !== "apartment") {
      throw new Error(location + " must resolve to the 308 apartment scene");
    }
  }
  if (normalizeEncounterSceneKey("頂樓出租屋", "躺在床上用吉他彈奏和弦") !== "apartment") {
    throw new Error("residential location must take precedence over incidental music activity");
  }
  for (const location of ["Live House", "練團室", "排練室", "錄音室", "音樂工作室"]) {
    if (normalizeEncounterSceneKey(location) !== "live-house") {
      throw new Error(location + " must resolve to Live House");
    }
  }
  if (normalizeEncounterSceneKey("私人工作室", "在地下樂團團練並排練新歌") !== "live-house") {
    throw new Error("music activity keywords must resolve to Live House even when the place name is generic");
  }
  if (normalizeEncounterSceneKey("後巷", "演出結束後在後巷休息並整理器材") !== "live-house") {
    throw new Error("post-show alley activities must resolve to Live House");
  }
  if (normalizeEncounterSceneKey("後巷", "在後巷散步") !== "shopping-street") {
    throw new Error("an alley without music or post-show context must remain a street scene");
  }
  if (normalizeEncounterSceneKey("小吃店") !== "shopping-street" ||
      normalizeEncounterSceneKey("路邊攤") !== "shopping-street" ||
      normalizeEncounterSceneKey("咖啡廳") !== "shopping-street" ||
      normalizeEncounterSceneKey("書店") !== "shopping-street") {
    throw new Error("street shops and small eateries must resolve to fixed scene F");
  }
  if (normalizeEncounterSceneKey("後巷") !== "shopping-street" ||
      normalizeEncounterSceneKey("巷口") !== "shopping-street" ||
      normalizeEncounterSceneKey("二手樂器行") !== "shopping-street" ||
      normalizeEncounterSceneKey("樂器行") !== "shopping-street") {
    throw new Error("alleys, street corners, and instrument shops must resolve to fixed scene F");
  }
  if (normalizeEncounterSceneKey("夜間酒吧", "晚上九點後進行樂團演出") !== "night-bar" ||
      normalizeEncounterSceneKey("Live House", "白天進行樂團演出") !== "live-house") {
    throw new Error("explicit night-bar and daytime Live House locations must remain distinct");
  }
});

Deno.test("prioritizes explicit fixed destinations over incidental activity keywords", () => {
  const musicActivity = "在現場聽樂團演出並跟著音樂節奏休息";
  if (normalizeEncounterSceneKey("機場", musicActivity) !== "airport" ||
      normalizeEncounterSceneKey("中央公園", musicActivity) !== "park" ||
      normalizeEncounterSceneKey("公司", musicActivity) !== "commercial" ||
      normalizeEncounterSceneKey("夜間酒吧", musicActivity) !== "night-bar" ||
      normalizeEncounterSceneKey("便利商店", musicActivity) !== "convenience-store") {
    throw new Error("explicit fixed destinations must not be overridden by incidental music activity");
  }
  if (normalizeEncounterSceneKey("私人工作室", "在地下樂團團練並排練新歌") !== "live-house") {
    throw new Error("generic venues may still use activity inference when no explicit scene matches");
  }
  if (normalizeEncounterSceneKey("未知的私人場所", "單純休息") !== null) {
    throw new Error("unrecognized locations must remain unresolved for safe fallback handling");
  }
});

Deno.test("uses structured character residence context for generic residential rooms", () => {
  const luxuryContext = "角色長期居住於高級公寓";
  if (normalizeEncounterSceneKey("臥室", "", luxuryContext) !== "luxury-apartment" ||
      normalizeEncounterSceneKey("客廳", "", luxuryContext) !== "luxury-apartment" ||
      normalizeEncounterSceneKey("書房", "", luxuryContext) !== "luxury-apartment" ||
      normalizeEncounterSceneKey("廚房", "", luxuryContext) !== "luxury-apartment" ||
      normalizeEncounterSceneKey("陽台", "", luxuryContext) !== "luxury-apartment") {
    throw new Error("generic rooms in an explicitly luxury residence must resolve to K");
  }
  if (normalizeEncounterSceneKey("臥室", "", "角色住在一般出租公寓") !== "apartment" ||
      normalizeEncounterSceneKey("臥室") !== "apartment" ||
      normalizeEncounterSceneKey("頂樓出租屋", "", luxuryContext) !== "apartment") {
    throw new Error("ordinary or explicitly rented residences must remain at L");
  }
  if (normalizeEncounterSceneKey("客戶家", "前往客戶的高級公寓拜訪", luxuryContext) !== "luxury-apartment" ||
      normalizeEncounterSceneKey("客戶家", "前往客戶家拜訪", luxuryContext) !== "apartment") {
    throw new Error("customer home must be classified from the customer's explicit context, not the character's residence");
  }

  const blocks = hourlyBlocks();
  blocks[10] = block(10, [
    option({ weight: 60, location: "臥室", activity: "在臥室整理衣物並準備出門" }),
    option({ weight: 40, location: "客廳", activity: "在客廳閱讀資料並喝咖啡" }),
  ]);
  const luxuryRole = source(id1, {
    derived_life_context: {
      residence: { status: "populated", items: [{ content: "角色長期居住於高級公寓" }] },
    },
  });
  const parsedLuxury = result(
    [{ character_id: id1, placement: "modern_map", variants: variants(blocks) }],
    [luxuryRole],
  );
  if (!parsedLuxury.ok ||
      parsedLuxury.characters[0].variants.weekday[10].options[0].location_key !== "luxury-apartment" ||
      parsedLuxury.characters[0].variants.weekday[10].options[1].location_key !== "luxury-apartment") {
    throw new Error("parser must apply structured luxury residence context to generic rooms: " + parsedLuxury.errors.join(","));
  }

  const ordinaryRole = source(id1, {
    derived_life_context: {
      residence: { status: "populated", items: [{ content: "角色居住於一般出租公寓" }] },
    },
  });
  const parsedOrdinary = result(
    [{ character_id: id1, placement: "modern_map", variants: variants(blocks) }],
    [ordinaryRole],
  );
  if (!parsedOrdinary.ok ||
      parsedOrdinary.characters[0].variants.weekday[10].options[0].location_key !== "apartment" ||
      parsedOrdinary.characters[0].variants.weekday[10].options[1].location_key !== "apartment") {
    throw new Error("ordinary residence context must keep generic rooms at L");
  }
});

Deno.test("maps existing character schedule locations without rewriting natural labels", () => {
  const weekday = hourlyBlocks();
  weekday[3] = block(3, [
    option({ weight: 60, location: "頂樓出租屋", activity: "淺眠狀態，偶爾翻身" }),
    option({ weight: 40, location: "頂樓出租屋", activity: "在床上翻身後繼續熟睡" }),
  ]);
  weekday[8] = block(8, [
    option({
      weight: 40,
      location: "Livehouse",
      activity: "在地下Livehouse進行試音，調整監聽耳機和吉他音量",
      is_outdoor: false,
      rain_fallback_location: "便利商店",
      rain_fallback_activity: "改在便利商店內買飲料並等雨勢變小",
    }),
    option({
      weight: 30,
      location: "頂樓出租屋",
      activity: "躺在床上休息，用吉他隨意彈些和弦打發時間",
    }),
    option({
      weight: 30,
      location: "後巷",
      activity: "演出結束後靠在紅磚牆邊抽菸，讓夜風慢慢吹散菸霧",
      is_outdoor: true,
      rain_fallback_location: "練團室",
      rain_fallback_activity: "改到練團室角落休息並整理器材",
    }),
  ]);
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(weekday) }]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  const options = parsed.characters[0].variants.weekday[8].options;
  if (options[0].location_key !== "live-house" || options[0].location_description !== "Livehouse") {
    throw new Error("Livehouse label must map to Live House without rewriting the original label");
  }
  if (options[0].rain_fallback_location_key !== "convenience-store") {
    throw new Error("convenience-store rain fallback must resolve to fixed scene M");
  }
  if (options[1].location_key !== "apartment" || options[1].location_description !== "頂樓出租屋") {
    throw new Error("residential location must stay in the apartment scene even when the activity mentions guitar");
  }
  if (options[2].location_key !== "live-house" || options[2].location_description !== "後巷") {
    throw new Error("post-show alley must use Live House while preserving its natural location");
  }
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
      parsed.characters[0].variants.weekday[8].options[0].location_key !== null) {
    throw new Error("unmapped natural locations must be preserved without inventing a fixed scene");
  }
  if (normalizeEncounterSceneKey("酒吧") !== "night-bar" ||
      normalizeEncounterSceneKey("辦公大樓") !== "commercial" ||
      normalizeEncounterSceneKey("咖啡廳") !== "shopping-street" ||
      normalizeEncounterSceneKey("展演廳") !== "live-house" ||
      normalizeEncounterSceneKey("代辦所") !== "commercial" ||
      normalizeEncounterSceneKey("歸途") !== "night-bar" ||
      normalizeEncounterSceneKey("餐廳") !== "department-store") throw new Error("canonical A–N scene aliases regressed");

  const tooLong = hourlyBlocks();
  tooLong[8] = block(8, [option({ weight: 60, location: "超級長的地點名稱超級長的地點名稱超級長的地點名稱超級長的地點名稱" }), option({ weight: 40 })]);
  const rejected = result([{ character_id: id1, placement: "modern_map", variants: variants(tooLong) }]);
  if (rejected.ok || !rejected.errors.some((error) => error.includes("location_invalid"))) {
    throw new Error("location label longer than twenty characters accepted");
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

Deno.test("recognizes contemporary musician settings and saved Profile context", () => {
  const musician = source(id1, {
    name: "陳曜司",
    intro: "午夜兩點的地下 Livehouse，演出剛結束。",
    world_era: "地下搖滾樂團的首席吉他手",
    race: "人類",
    modern_setting_compatible: false,
    time_travel_explicit: false,
    schedule_description: "晚上前往固定駐演的地下 Livehouse 試音，結束後騎重機回頂樓出租屋，偶爾到宵夜攤吃東西。",
  });
  const classification = classifyEncounterWorldview(musician);
  if (classification.category !== "modern" || !classification.modern_map_compatible) {
    throw new Error("contemporary musician context was incorrectly held for review: " + JSON.stringify(classification));
  }

  const profileOnlySignal = source(id1, {
    name: "測試角色",
    intro: "一位神秘旅人。",
    world_era: "",
    modern_setting_compatible: false,
    time_travel_explicit: false,
    schedule_description: "",
    personality_profile: {},
    derived_character_profile: {
      identity_background: { status: "populated", items: [{ content: "現代地下樂團的吉他手，固定在 Live House 演出。" }] },
    },
    derived_life_context: {
      daily_routines: { status: "populated", items: [{ content: "騎重機回出租屋，深夜吃宵夜。" }] },
    },
  });
  const profileClassification = classifyEncounterWorldview(profileOnlySignal);
  if (!profileClassification.modern_map_compatible || profileClassification.category !== "modern") {
    throw new Error("saved derived Character AI Profile was ignored during worldview classification");
  }
});

Deno.test("recognizes contemporary nightlife host settings as modern", () => {
  const nightlifeRole = source(id1, {
    name: "陳曜陽－LUCID",
    intro: "在繁華夜生活的心臟地帶，頂級男公關俱樂部 LUCID 是現代都市中的高級娛樂場所。",
    tags: ["牛郎", "男公關", "毒舌"],
    world_era: "現代夜生活與男公關俱樂部",
    modern_setting_compatible: false,
    schedule_description: "傍晚進入俱樂部，在 VIP 私人工作室接待客人，平日住在公寓。",
  });
  const classification = classifyEncounterWorldview(nightlifeRole);
  if (classification.category !== "modern" || !classification.modern_map_compatible ||
      getEncounterWorldviewScheduleDisposition(classification) !== "generate") {
    throw new Error("contemporary nightlife host setting must proceed to modern-map schedule generation: " + JSON.stringify(classification));
  }
});

Deno.test("recognizes contemporary interior-design and construction professions as modern", () => {
  const designProfessional = source(id1, {
    name: "江辰遠",
    intro: "住在城市公寓，任職於知名設計事務所的室內設計師，專長空間規劃與家居美學。",
    world_era: "",
    modern_setting_compatible: false,
    time_travel_explicit: false,
    schedule_description: "平日前往設計工地監工，與施工工班確認進度，傍晚回工作室繪製設計圖。",
    private_info: "曾在裝修工程與樣品屋現場協調空間配置。",
  });
  const classification = classifyEncounterWorldview(designProfessional);
  if (classification.category !== "modern" || !classification.modern_map_compatible ||
      getEncounterWorldviewScheduleDisposition(classification) !== "generate") {
    throw new Error("contemporary interior-design profession was incorrectly held for review: " + JSON.stringify(classification));
  }
  const promptPayload = JSON.parse(buildEncounterScheduleBatchMessages([designProfessional]).messages[1].content).characters[0];
  if (promptPayload.modern_setting_compatible !== true) {
    throw new Error("modern-map compatibility was not passed to the schedule AI for a contemporary design professional");
  }
  const parsed = result([{
    character_id: id1, placement: "modern_map", variants: variants(),
  }], [designProfessional]);
  if (!parsed.ok) throw new Error("modern-map schedule for a contemporary design professional was rejected: " + parsed.errors.join(","));

  const historicalDesigner = source(id1, {
    intro: "中世紀古堡中的室內設計師，負責規劃領主寢宮。",
    world_era: "medieval",
    modern_setting_compatible: false,
    schedule_description: "",
  });
  if (classifyEncounterWorldview(historicalDesigner).category !== "historical" ||
      isEncounterModernMapCompatible(historicalDesigner)) {
    throw new Error("historical era must retain priority over contemporary profession keywords");
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
  const taggedModernFantasy = classifyEncounterWorldview(source(id1, {
    race: "狼人",
    worldview_tags: ["modern", "fantasy"],
    intro: "居住在現代城市的狼人。",
  }));
  if (taggedModernFantasy.category !== "modern_fantasy" || !taggedModernFantasy.modern_map_compatible) {
    throw new Error("author tags modern+fantasy should be modern-map compatible");
  }
  const taggedAncientFantasy = classifyEncounterWorldview(source(id1, {
    worldview_tags: ["ancient", "fantasy"],
    intro: "修仙宗門中的狐妖。",
  }));
  if (taggedAncientFantasy.modern_map_compatible) {
    throw new Error("author tags ancient+fantasy must not be forced onto the modern map");
  }
  const taggedFantasyOnly = classifyEncounterWorldview(source(id1, { worldview_tags: ["fantasy"] }));
  if (taggedFantasyOnly.category !== "fantasy" || taggedFantasyOnly.modern_map_compatible) {
    throw new Error("fantasy-only author tag should not imply a modern era");
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
  if (classifyEncounterActivitySpace("室內裝修監工與水電管線確認", "豪宅", false) !== "indoor") {
    throw new Error("indoor residential construction must remain indoors");
  }
  if (classifyEncounterActivitySpace("道路施工與路面修繕監督", "商店街", false) !== "outdoor") {
    throw new Error("road construction must be weather-exposed outdoor activity");
  }
  if (classifyEncounterActivitySpace("公園步道整修與景觀施工", "公園", false) !== "outdoor") {
    throw new Error("park path construction must be classified as outdoor");
  }
  if (normalizeEncounterSceneKey("工地", "室內裝修監工") !== null) {
    throw new Error("generic worksite must not become a standalone map scene");
  }
  if (normalizeEncounterSceneKey("豪宅", "室內裝修監工") !== "luxury-apartment") {
    throw new Error("luxury residence construction should map to the existing luxury-apartment scene");
  }
  if (normalizeEncounterSceneKey("店面", "店內裝修") !== "shopping-street") {
    throw new Error("shopfront construction should map to the existing shopping-street scene");
  }
  if (normalizeEncounterSceneKey("校舍", "校舍修繕") !== "university") {
    throw new Error("school building construction should map to the existing university scene");
  }

  const unknown = source(id1, {
    intro: "一位神秘旅人。", world_era: "", modern_setting_compatible: false,
    schedule_description: "", private_info: "", personality_profile: {},
  });
  const unknownClass = classifyEncounterWorldview(unknown);
  if (unknownClass.category !== "unknown" || unknownClass.modern_map_compatible) {
    throw new Error("unknown worldview must be held out of the modern map");
  }
  if (getEncounterWorldviewScheduleDisposition(unknownClass) !== "generate") {
    throw new Error("unknown legacy worldview must generate instead of blocking schedule publication");
  }
  if (!isEncounterModernMapCompatible(unknown)) {
    throw new Error("unknown legacy characters should be allowed through the safe scene resolver");
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

Deno.test("keeps sleeping detection aligned across frontend and server availability", () => {
  for (const activity of ["正在熟睡", "睡夢中，隱約聽到樓下早餐店的聲音", "深層睡眠中", "淺眠中", "睡得很沉"]) {
    if (resolveEncounterScheduleAvailability(activity) !== "sleeping") {
      throw new Error("sleeping activity not detected: " + activity);
    }
  }
  if (resolveEncounterScheduleAvailability("準備睡覺前整理房間") !== "available") {
    throw new Error("preparing for sleep incorrectly blocked");
  }
  if (resolveEncounterScheduleAvailability("在家休息") !== "available") {
    throw new Error("ordinary rest incorrectly blocked");
  }
  if (resolveEncounterScheduleAvailability("補眠", "手機放在茶几上保持待命狀態，隨時準備接聽電話") !== "available") {
    throw new Error("on-call rest must remain available for an Encounter");
  }
  if (resolveEncounterScheduleAvailability("補眠", "手機靜音，請勿打擾") !== "sleeping") {
    throw new Error("rest without an explicit availability signal must remain unavailable");
  }
  if (resolveEncounterScheduleAvailability("深層睡眠", "手機保持待命") !== "sleeping") {
    throw new Error("explicit deep sleep must override unrelated standby wording");
  }
  if (resolveEncounterScheduleAvailability("午睡", "手機保持待命，隨時接聽電話") !== "available") {
    throw new Error("clear standby instruction must override generic nap wording");
  }
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
      !prompt.includes("8–30 個中文字") ||
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
