import { preparePrivateContext } from "./private-context-guard.ts";

export const ENCOUNTER_SCHEDULE_BATCH_LIMIT = 10;
export const ENCOUNTER_SCHEDULE_VARIANT_WEIGHTS = {
  weekday: { primary: 80, alternative: 20 },
  holiday: { primary: 60, alternative: 40 },
} as const;
export const ENCOUNTER_SCHEDULE_MAX_SLOTS_PER_VARIANT = 4;

export const ENCOUNTER_SCENE_KEYS = [
  "airport", "commercial", "night-bar", "live-house", "apartment",
  "department-store", "bookstore", "cafe", "park", "shopping-street",
] as const;

const INDOOR_SCENE_KEYS = new Set([
  "airport", "commercial", "night-bar", "live-house", "apartment",
  "department-store", "bookstore", "cafe",
]);
const OUTDOOR_SCENE_KEYS = new Set(["park", "shopping-street"]);
const NON_MODERN_ERA_PATTERN = /ancient|historical|medieval|antiquity|fantasy|mythic|fictional|古代|歷史|中世紀|中古|奇幻|架空|封建|戰國|春秋|秦漢|唐代|宋代|明代|清代|古羅馬|古希臘/i;
const SCENE_ALIASES: Record<string, string> = {
  bar: "night-bar", pub: "night-bar", 酒吧: "night-bar", 酒館: "night-bar", 夜店: "night-bar",
  公司: "commercial", 商辦: "commercial", 辦公大樓: "commercial", 辦公室: "commercial", 企業大樓: "commercial",
  咖啡店: "cafe", 咖啡廳: "cafe", cafe: "cafe",
  書店: "bookstore", bookstore: "bookstore",
  百貨: "department-store", 百貨公司: "department-store", department: "department-store",
  公園: "park", park: "park",
  機場: "airport", airport: "airport",
  公寓: "apartment", 住宅: "apartment", apartment: "apartment",
  livehouse: "live-house", "live house": "live-house", 現場音樂: "live-house", 音樂展演: "live-house",
  購物街: "shopping-street", 商店街: "shopping-street", 逛街商圈: "shopping-street",
};

type RecordValue = Record<string, unknown>;
type ScheduleSlot = {
  start_time: string;
  end_time: string;
  location_key: string;
  activity: string;
  is_outdoor: boolean;
  rain_fallback_location_key: string | null;
  rain_fallback_activity: string | null;
  encounter_greeting: string;
};
type ScheduleVariant = {
  variant_key: "primary" | "alternative";
  weight: number;
  slots: ScheduleSlot[];
};
export type GeneratedCharacterSchedule = {
  character_id: string;
  placement: "modern_map" | "no_matching_location";
  variants: {
    weekday: ScheduleVariant[];
    holiday: ScheduleVariant[];
  };
};
export type EncounterScheduleSource = RecordValue & {
  character_id: string;
  author_id: string;
};

const isRecord = (value: unknown): value is RecordValue =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const text = (value: unknown): string => typeof value === "string" ? value.trim() : "";
const isUuid = (value: unknown): value is string =>
  typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const hasExactKeys = (value: unknown, keys: readonly string[]): value is RecordValue =>
  isRecord(value) && Object.keys(value).length === keys.length &&
  keys.every((key) => Object.prototype.hasOwnProperty.call(value, key));

export function normalizeEncounterSceneKey(value: unknown): string | null {
  const raw = text(value).toLocaleLowerCase();
  if ((ENCOUNTER_SCENE_KEYS as readonly string[]).includes(raw)) return raw;
  return SCENE_ALIASES[raw] || SCENE_ALIASES[text(value)] || null;
}

export function isEncounterModernMapCompatible(source: EncounterScheduleSource): boolean {
  const era = [text(source.world_era), text(source.setting_era), text(source.intro)].filter(Boolean).join(" ");
  const nonModern = NON_MODERN_ERA_PATTERN.test(era);
  return !nonModern || source.modern_setting_compatible === true || source.time_travel_explicit === true;
}

function parseHour(value: unknown): number | null {
  if (typeof value !== "string" || !/^([01][0-9]|2[0-3]):00$/.test(value)) return null;
  return Number(value.slice(0, 2)) * 60;
}

function durationMinutes(start: number, end: number): number {
  const adjustedEnd = end <= start ? end + 1440 : end;
  return adjustedEnd - start;
}

function intervalsOverlap(a: { start: number; end: number }, b: { start: number; end: number }): boolean {
  for (const offset of [-1440, 0, 1440]) {
    if (a.start < b.end + offset && b.start + offset < a.end) return true;
  }
  return false;
}

function validateSlot(value: unknown, errors: string[], label: string): ScheduleSlot | null {
  const keys = [
    "start_time", "end_time", "location_key", "activity", "is_outdoor",
    "rain_fallback_location_key", "rain_fallback_activity", "encounter_greeting",
  ];
  if (!hasExactKeys(value, keys)) {
    errors.push(label + "_slot_keys_invalid");
    return null;
  }
  const start = parseHour(value.start_time);
  const end = parseHour(value.end_time);
  const location = normalizeEncounterSceneKey(value.location_key);
  const activity = text(value.activity);
  const greeting = text(value.encounter_greeting);
  if (start === null || end === null || start === end || !location) errors.push(label + "_slot_time_or_location_invalid");
  if (!activity || activity.length > 200) errors.push(label + "_activity_invalid");
  if (typeof value.is_outdoor !== "boolean") errors.push(label + "_outdoor_flag_invalid");
  if (Array.from(greeting).length < 150 || Array.from(greeting).length > 300) errors.push(label + "_greeting_length_invalid");

  let rainLocation: string | null = null;
  let rainActivity: string | null = null;
  if (value.is_outdoor === true) {
    rainLocation = normalizeEncounterSceneKey(value.rain_fallback_location_key);
    rainActivity = text(value.rain_fallback_activity);
    if (!rainLocation || !INDOOR_SCENE_KEYS.has(rainLocation) || !rainActivity || rainActivity.length > 200) {
      errors.push(label + "_rain_fallback_invalid");
    }
  } else if (value.rain_fallback_location_key !== null || value.rain_fallback_activity !== null) {
    errors.push(label + "_unexpected_rain_fallback");
  }
  if (location && value.is_outdoor === true && !OUTDOOR_SCENE_KEYS.has(location)) {
    errors.push(label + "_outdoor_location_mismatch");
  }
  if (location && value.is_outdoor === false && OUTDOOR_SCENE_KEYS.has(location)) {
    errors.push(label + "_indoor_location_mismatch");
  }
  if (start !== null && end !== null && start !== end) {
    const duration = durationMinutes(start, end);
    if (duration < 60 || duration > 1440 || duration % 60 !== 0) errors.push(label + "_duration_invalid");
  }
  return {
    start_time: text(value.start_time),
    end_time: text(value.end_time),
    location_key: location || "",
    activity,
    is_outdoor: value.is_outdoor === true,
    rain_fallback_location_key: rainLocation,
    rain_fallback_activity: rainActivity,
    encounter_greeting: greeting,
  };
}

function validateVariant(
  value: unknown,
  dayType: "weekday" | "holiday",
  expectedKey: "primary" | "alternative",
  expectedWeight: number,
  errors: string[],
  label: string,
): ScheduleVariant | null {
  if (!hasExactKeys(value, ["variant_key", "weight", "slots"]) ||
    value.variant_key !== expectedKey || value.weight !== expectedWeight || !Array.isArray(value.slots)) {
    errors.push(label + "_variant_contract_invalid");
    return null;
  }
  if (value.slots.length < 1 || value.slots.length > ENCOUNTER_SCHEDULE_MAX_SLOTS_PER_VARIANT) {
    errors.push(label + "_slot_count_invalid");
  }
  const slots = value.slots.slice(0, ENCOUNTER_SCHEDULE_MAX_SLOTS_PER_VARIANT)
    .map((slot, index) => validateSlot(slot, errors, label + "_slot_" + index))
    .filter((slot): slot is ScheduleSlot => slot !== null);
  const intervals = slots.map((slot) => {
    const start = parseHour(slot.start_time) ?? 0;
    const end = parseHour(slot.end_time) ?? 0;
    return { start, end: end <= start ? end + 1440 : end };
  });
  for (let i = 0; i < intervals.length; i++) {
    for (let j = i + 1; j < intervals.length; j++) {
      if (intervalsOverlap(intervals[i], intervals[j])) errors.push(label + "_slots_overlap");
    }
  }
  return { variant_key: expectedKey, weight: expectedWeight, slots };
}

export function buildEncounterScheduleBatchMessages(sources: EncounterScheduleSource[]): {
  messages: Array<{ role: "system" | "user"; content: string }>;
  protectedContextByCharacter: Record<string, string[]>;
} {
  if (!Array.isArray(sources) || sources.length < 1 || sources.length > ENCOUNTER_SCHEDULE_BATCH_LIMIT) {
    throw new Error("encounter_schedule_batch_size_invalid");
  }
  const protectedContextByCharacter: Record<string, string[]> = {};
  const promptSources = sources.map((source) => {
    if (!isUuid(source.character_id) || !isUuid(source.author_id)) throw new Error("encounter_schedule_source_identity_invalid");
    const privateContext = preparePrivateContext(
      [text(source.private_info), text(source.schedule_description)].filter(Boolean).join("\n"),
      isRecord(source.personality_profile) ? source.personality_profile : {},
    );
    protectedContextByCharacter[source.character_id] = privateContext.protectedValues;
    return {
      character_id: source.character_id,
      name: text(source.name),
      intro: text(source.intro),
      race: text(source.race),
      style: text(source.style),
      gender: text(source.gender),
      age: text(source.age),
      occupation: text(source.occupation),
      world_era: text(source.world_era),
      modern_setting_compatible: source.modern_setting_compatible === true,
      time_travel_explicit: source.time_travel_explicit === true,
      author_schedule_brief: text(source.schedule_description),
      author_private_context: privateContext.promptText,
    };
  });
  const system = [
    "你是 POYOZZ 的角色行程規劃器。一次為提供的 1 至 10 個公開角色整理可驗證的城市地圖行程。",
    "只使用輸入角色的設定與作者提供的行程方向，不可替角色創造與背景衝突的現代身分。歷史／古代角色若沒有作者明確設定現代相容或明確穿越，必須 placement=no_matching_location，不可放進現代城市地圖。奇幻種族只要背景明確相容現代世界，就可以正常安排。",
    "相似職業或場景必須共用 canonical location_key：酒吧老闆／酒保／酒吧員工共用 night-bar；企業主／主管／秘書共用 commercial；咖啡相關共用 cafe。不可為每個角色各造一個相似地點。",
    "可提出 shopping-street 作為新場景候選，但只有當本批至少兩個不同角色共用它時才保留；若只有一個角色使用，請改用最接近的既有地點。不可輸出座標、圖片 URL、Storage path 或自行發明地標 ID。",
    "每天以整點為單位規劃。連續多小時在同一地點從事同一活動，合併為一個 start_time/end_time 區間；例如 09:00–17:00 的 8 小時工作必須留在同一地點。每個變體最多 4 個時段，可保留合理空檔。",
    "每個 weekday 變體權重固定 primary=80、alternative=20；每個 holiday 變體權重固定 primary=60、alternative=40。每個日型都必須提供 primary 與 alternative 兩套完整行程。",
    "戶外時段必須提供雨天室內替代地點與活動；室內時段 rain_fallback_location_key 與 rain_fallback_activity 必須為 null。park 與 shopping-street 為戶外；其餘提供的地點為室內。",
    "每個時段都要產生一段與該角色、地點、活動吻合的預生成招呼 encounter_greeting，長度 150–300 字元；不得直接揭露作者私密設定或照抄私密內容。",
    "只可使用 location_key: airport, commercial, night-bar, live-house, apartment, department-store, bookstore, cafe, park, shopping-street。場景類別不明或角色無現代地圖相容地點時，使用 no_matching_location 並回傳空 variants。",
    "輸出必須是嚴格 JSON object，唯一根欄位 characters。每個角色欄位為 character_id, placement, variants。variants 只包含 weekday 與 holiday；各自為兩個 variant 物件。variant 物件欄位為 variant_key, weight, slots。slot 欄位為 start_time, end_time, location_key, activity, is_outdoor, rain_fallback_location_key, rain_fallback_activity, encounter_greeting。不可輸出額外欄位或 Markdown。",
  ].join("\n");
  return {
    messages: [
      { role: "system", content: system },
      { role: "user", content: JSON.stringify({ characters: promptSources }) },
    ],
    protectedContextByCharacter,
  };
}

export function parseEncounterScheduleBatchOutput(
  raw: string,
  sources: EncounterScheduleSource[],
): { ok: boolean; characters: GeneratedCharacterSchedule[]; errors: string[] } {
  const errors: string[] = [];
  let parsed: unknown;
  try { parsed = JSON.parse(String(raw ?? "")); } catch { return { ok: false, characters: [], errors: ["output_json_invalid"] }; }
  if (!hasExactKeys(parsed, ["characters"]) || !Array.isArray(parsed.characters)) {
    return { ok: false, characters: [], errors: ["output_root_invalid"] };
  }
  const sourceById = new Map(sources.map((source) => [source.character_id, source]));
  if (parsed.characters.length !== sources.length) errors.push("character_count_mismatch");
  const seen = new Set<string>();
  const characters: GeneratedCharacterSchedule[] = [];
  for (const item of parsed.characters) {
    if (!hasExactKeys(item, ["character_id", "placement", "variants"]) || !isUuid(item.character_id)) {
      errors.push("character_item_invalid");
      continue;
    }
    const id = item.character_id;
    const source = sourceById.get(id);
    if (!source || seen.has(id)) {
      errors.push("character_identity_duplicate_or_unknown");
      continue;
    }
    seen.add(id);
    if (item.placement === "no_matching_location") {
      if (!hasExactKeys(item.variants, ["weekday", "holiday"]) ||
        !Array.isArray(item.variants.weekday) || item.variants.weekday.length !== 0 ||
        !Array.isArray(item.variants.holiday) || item.variants.holiday.length !== 0) {
        errors.push(id + "_no_location_variants_must_be_empty");
      }
      characters.push({ character_id: id, placement: "no_matching_location", variants: { weekday: [], holiday: [] } });
      continue;
    }
    if (item.placement !== "modern_map" || !isEncounterModernMapCompatible(source)) {
      errors.push(id + "_modern_map_placement_not_allowed");
      continue;
    }
    if (!hasExactKeys(item.variants, ["weekday", "holiday"]) ||
      !Array.isArray(item.variants.weekday) || !Array.isArray(item.variants.holiday) ||
      item.variants.weekday.length !== 2 || item.variants.holiday.length !== 2) {
      errors.push(id + "_day_type_variants_invalid");
      continue;
    }
    const weekday = [
      validateVariant(item.variants.weekday[0], "weekday", "primary", 80, errors, id + "_weekday_primary"),
      validateVariant(item.variants.weekday[1], "weekday", "alternative", 20, errors, id + "_weekday_alternative"),
    ].filter((value): value is ScheduleVariant => value !== null);
    const holiday = [
      validateVariant(item.variants.holiday[0], "holiday", "primary", 60, errors, id + "_holiday_primary"),
      validateVariant(item.variants.holiday[1], "holiday", "alternative", 40, errors, id + "_holiday_alternative"),
    ].filter((value): value is ScheduleVariant => value !== null);
    if (weekday.length === 2 && holiday.length === 2) {
      characters.push({ character_id: id, placement: "modern_map", variants: { weekday, holiday } });
    }
  }

  // A new shared shopping-street marker is only justified when at least two
  // different public characters use it in this batch. Otherwise normalize to
  // the existing department-store scene to avoid map clutter.
  const shoppingStreetUsers = new Set<string>();
  for (const character of characters) {
    for (const variant of [...character.variants.weekday, ...character.variants.holiday]) {
      for (const slot of variant.slots) if (slot.location_key === "shopping-street") shoppingStreetUsers.add(character.character_id);
    }
  }
  if (shoppingStreetUsers.size < 2) {
    for (const character of characters) {
      for (const variant of [...character.variants.weekday, ...character.variants.holiday]) {
        for (const slot of variant.slots) {
          if (slot.location_key === "shopping-street") {
            slot.location_key = "department-store";
            slot.is_outdoor = false;
            slot.rain_fallback_location_key = null;
            slot.rain_fallback_activity = null;
          }
          if (slot.rain_fallback_location_key === "shopping-street") slot.rain_fallback_location_key = "department-store";
        }
      }
    }
  }

  if (seen.size !== sources.length) errors.push("character_coverage_incomplete");
  return { ok: errors.length === 0, characters: errors.length === 0 ? characters : [], errors: [...new Set(errors)] };
}
