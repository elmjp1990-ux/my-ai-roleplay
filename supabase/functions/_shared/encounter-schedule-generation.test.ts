import {
  buildEncounterScheduleBatchMessages,
  isEncounterModernMapCompatible,
  normalizeEncounterSceneKey,
  parseEncounterScheduleBatchOutput,
} from "./encounter-schedule-generation.ts";

const id1 = "11111111-1111-4111-8111-111111111111";
const id2 = "22222222-2222-4222-8222-222222222222";
const author = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const greeting = "相遇內容。".repeat(30);
const source = (character_id = id1, extra = {}) => ({
  character_id, author_id: author, visibility: "public", review_status: "approved", rights_confirmed: true, deleted_at: null,
  name: "測試角色", intro: "現代城市生活",
  world_era: "modern", modern_setting_compatible: true, time_travel_explicit: false,
  schedule_description: "白天在公司工作，晚上和朋友見面",
  private_info: "只供角色一致性使用的私密設定", personality_profile: { tone: "溫柔" },
  ...extra,
});
const slot = (extra = {}) => ({
  start_time: "09:00", end_time: "17:00", location_key: "commercial",
  activity: "在公司處理工作", is_outdoor: false,
  rain_fallback_location_key: null, rain_fallback_activity: null, rain_fallback_greeting: null,
  encounter_greeting: greeting, ...extra,
});
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
    { variant_key: "primary", weight: 60, slots: fullDaySlots({ start_time: "08:00", end_time: "16:00", location_key: "park", activity: "在公園散步" }) },
    { variant_key: "alternative", weight: 40, slots: fullDaySlots({ start_time: "08:00", end_time: "16:00", location_key: "department-store", activity: "逛百貨公司" }) },
  ],
});
const result = (characters) => parseEncounterScheduleBatchOutput(JSON.stringify({ characters }), characters.map((c) => source(c.character_id)));

Deno.test("accepts hourly schedules with exact weekday/holiday weights and 8-hour continuous work", () => {
  const parsed = parseEncounterScheduleBatchOutput(JSON.stringify({
    characters: [{ character_id: id1, placement: "modern_map", variants: variants() }],
  }), [source()]);
  if (!parsed.ok) throw new Error(parsed.errors.join(","));
  if (parsed.characters[0].variants.weekday[0].slots[1].end_time !== "16:00") throw new Error("8-hour slot changed");
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

Deno.test("rejects gaps in the 24-hour daily schedule", () => {
  const incomplete = fullDaySlots();
  incomplete[1] = slot({ start_time: "09:00", end_time: "16:00" });
  const parsed = result([{ character_id: id1, placement: "modern_map", variants: variants(incomplete) }]);
  if (parsed.ok || !parsed.errors.some((error) => error.includes("24_hour_coverage_incomplete"))) {
    throw new Error("daily schedule gap accepted");
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
});

Deno.test("only retains a new shopping-street scene when multiple characters share it", () => {
  const single = result([{
    character_id: id1, placement: "modern_map",
    variants: variants(fullDaySlots({ location_key: "shopping-street", is_outdoor: true,
      rain_fallback_location_key: "cafe", rain_fallback_activity: "改在咖啡廳", rain_fallback_greeting: greeting })]),
  }]);
  if (!single.ok || single.characters[0].variants.weekday[0].slots[1].location_key !== "department-store") {
    throw new Error("unshared scene should collapse into an existing marker");
  }
  if (single.characters[0].variants.weekday[0].slots[1].is_outdoor ||
    single.characters[0].variants.weekday[0].slots[1].rain_fallback_location_key !== null) {
    throw new Error("collapsed scene should use indoor semantics");
  }
  const two = parseEncounterScheduleBatchOutput(JSON.stringify({
    characters: [
      { character_id: id1, placement: "modern_map", variants: variants(fullDaySlots({ location_key: "shopping-street", is_outdoor: true,
        rain_fallback_location_key: "cafe", rain_fallback_activity: "改在咖啡廳", rain_fallback_greeting: greeting })]) },
      { character_id: id2, placement: "modern_map", variants: variants(fullDaySlots({ location_key: "shopping-street", is_outdoor: true,
        rain_fallback_location_key: "bookstore", rain_fallback_activity: "改在書店", rain_fallback_greeting: greeting })]) },
    ],
  }), [source(id1), source(id2)]);
  if (!two.ok || two.characters[0].variants.weekday[0].slots[1].location_key !== "shopping-street") {
    throw new Error("shared new scene candidate was not retained");
  }
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
