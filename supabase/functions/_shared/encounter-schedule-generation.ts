import { preparePrivateContext } from "./private-context-guard.ts";

export const ENCOUNTER_SCHEDULE_BATCH_LIMIT = 10;
export const ENCOUNTER_SCHEDULE_VARIANT_WEIGHTS = {
  weekday: { primary: 80, alternative: 20 },
  holiday: { primary: 60, alternative: 40 },
} as const;
export const ENCOUNTER_SCHEDULE_MAX_SLOTS_PER_VARIANT = 4;

export const ENCOUNTER_SPECIAL_EVENT_KEYS = [
  "taiwan_public_holiday", "lunar_new_year", "valentines_day", "christmas",
] as const;

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
  rain_fallback_greeting: string | null;
  encounter_greeting: string;
};
type ScheduleVariant = {
  variant_key: "primary" | "alternative";
  weight: number;
  slots: ScheduleSlot[];
};
type SpecialEventSchedule = {
  event_key: typeof ENCOUNTER_SPECIAL_EVENT_KEYS[number];
  event_name: string;
  slots: ScheduleSlot[];
};
export const ENCOUNTER_RELATIONSHIP_STAGES = [
  "hostile", "dislike", "wary", "first_meeting",
  "acquaintance", "close", "intimate", "special",
] as const;
export type EncounterRelationshipStage = typeof ENCOUNTER_RELATIONSHIP_STAGES[number];
export type EncounterRelationshipGreetingPools = Record<EncounterRelationshipStage, string[]>;
export type GeneratedCharacterSchedule = {
  character_id: string;
  placement: "modern_map" | "no_matching_location";
  variants: {
    weekday: ScheduleVariant[];
    holiday: ScheduleVariant[];
  };
  special_events: SpecialEventSchedule[];
  relationship_greetings?: EncounterRelationshipGreetingPools;
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
    "rain_fallback_location_key", "rain_fallback_activity", "rain_fallback_greeting", "encounter_greeting",
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
  let rainGreeting: string | null = null;
  if (value.is_outdoor === true) {
    rainLocation = normalizeEncounterSceneKey(value.rain_fallback_location_key);
    rainActivity = text(value.rain_fallback_activity);
    rainGreeting = text(value.rain_fallback_greeting);
    if (!rainLocation || !INDOOR_SCENE_KEYS.has(rainLocation) || !rainActivity || rainActivity.length > 200 ||
      Array.from(rainGreeting).length < 150 || Array.from(rainGreeting).length > 300) {
      errors.push(label + "_rain_fallback_invalid");
    }
  } else if (value.rain_fallback_location_key !== null || value.rain_fallback_activity !== null || value.rain_fallback_greeting !== null) {
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
    rain_fallback_greeting: rainGreeting,
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
  if (value.slots.length < 2 || value.slots.length > ENCOUNTER_SCHEDULE_MAX_SLOTS_PER_VARIANT) {
    errors.push(label + "_slot_count_invalid");
  }
  const slots = value.slots.slice(0, ENCOUNTER_SCHEDULE_MAX_SLOTS_PER_VARIANT)
    .map((slot, index) => validateSlot(slot, errors, label + "_slot_" + index))
    .filter((slot): slot is ScheduleSlot => slot !== null);
  const orderedSlots = slots.slice().sort((a, b) => (parseHour(a.start_time) ?? 0) - (parseHour(b.start_time) ?? 0));
  for (let i = 1; i < orderedSlots.length; i++) {
    const previous = orderedSlots[i - 1];
    const current = orderedSlots[i];
    if (previous.end_time === current.start_time &&
      previous.location_key === current.location_key &&
      previous.activity === current.activity &&
      previous.is_outdoor === current.is_outdoor &&
      previous.rain_fallback_location_key === current.rain_fallback_location_key &&
      previous.rain_fallback_activity === current.rain_fallback_activity) {
      errors.push(label + "_adjacent_same_activity_slots_should_merge");
    }
  }
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
  const dailyIntervals = intervals.slice().sort((a, b) => a.start - b.start);
  if (dailyIntervals[0]?.start !== 0 || dailyIntervals[dailyIntervals.length - 1]?.end !== 1440 ||
    dailyIntervals.some((interval, index) => index > 0 && dailyIntervals[index - 1].end !== interval.start)) {
    errors.push(label + "_24_hour_coverage_incomplete");
  }
  return { variant_key: expectedKey, weight: expectedWeight, slots };
}

function validateRelationshipGreetingPools(
  value: unknown,
  errors: string[],
  label: string,
): EncounterRelationshipGreetingPools | null {
  if (!hasExactKeys(value, ENCOUNTER_RELATIONSHIP_STAGES)) {
    errors.push(label + "_relationship_greeting_stages_invalid");
    return null;
  }
  const pools = {} as EncounterRelationshipGreetingPools;
  for (const stage of ENCOUNTER_RELATIONSHIP_STAGES) {
    const rawPool = value[stage];
    if (!Array.isArray(rawPool) || rawPool.length < 3 || rawPool.length > 5) {
      errors.push(label + "_" + stage + "_greeting_pool_count_invalid");
      continue;
    }
    const greetings = rawPool.map((item) => text(item));
    if (greetings.some((greeting) => Array.from(greeting).length < 150 || Array.from(greeting).length > 300)) {
      errors.push(label + "_" + stage + "_greeting_pool_length_invalid");
      continue;
    }
    if (new Set(greetings.map((greeting) => greeting.normalize("NFKC"))).size !== greetings.length) {
      errors.push(label + "_" + stage + "_greeting_pool_duplicate");
      continue;
    }
    pools[stage] = greetings;
  }
  return ENCOUNTER_RELATIONSHIP_STAGES.every((stage) => Array.isArray(pools[stage])) ? pools : null;
}

function validateSpecialEvent(value: unknown, errors: string[], label: string): SpecialEventSchedule | null {
  if (!hasExactKeys(value, ["event_key", "event_name", "slots"])) {
    errors.push(label + "_special_event_keys_invalid");
    return null;
  }
  const eventKey = text(value.event_key);
  const eventName = text(value.event_name);
  if (!(ENCOUNTER_SPECIAL_EVENT_KEYS as readonly string[]).includes(eventKey) ||
    Array.from(eventName).length < 1 || Array.from(eventName).length > 40 ||
    !Array.isArray(value.slots)) {
    errors.push(label + "_special_event_shape_invalid");
    return null;
  }
  const variant = validateVariant(
    { variant_key: "primary", weight: 100, slots: value.slots },
    "holiday",
    "primary",
    100,
    errors,
    label,
  );
  if (!variant) return null;
  return {
    event_key: eventKey as SpecialEventSchedule["event_key"],
    event_name: eventName,
    slots: variant.slots,
  };
}

export function buildEncounterScheduleBatchMessages(sources: EncounterScheduleSource[]): {
  messages: Array<{ role: "system" | "user"; content: string }>;
  protectedContextByCharacter: Record<string, string[]>;
} {
  if (!Array.isArray(sources) || sources.length < 1 || sources.length > ENCOUNTER_SCHEDULE_BATCH_LIMIT) {
    throw new Error("encounter_schedule_batch_size_invalid");
  }
  if (new Set(sources.map((source) => source.character_id)).size !== sources.length) {
    throw new Error("encounter_schedule_character_ids_not_unique");
  }
  const protectedContextByCharacter: Record<string, string[]> = {};
  const promptSources = sources.map((source) => {
    if (!isUuid(source.character_id) || !isUuid(source.author_id)) throw new Error("encounter_schedule_source_identity_invalid");
    if (source.visibility !== "public" || source.review_status !== "approved" || source.rights_confirmed !== true || source.deleted_at != null) throw new Error("encounter_schedule_source_not_public");
    const characterProfile = isRecord(source.personality_profile) ? source.personality_profile : {};
    const occupation = text(source.occupation) || text(characterProfile.occupation)
      || text(characterProfile.job) || text(characterProfile.profession);
    const privateContext = preparePrivateContext(text(source.private_info), characterProfile);
    protectedContextByCharacter[source.character_id] = privateContext.protectedValues;
    return {
      character_id: source.character_id,
      name: text(source.name),
      title: text(source.title),
      intro: text(source.intro),
      race: text(source.race),
      style: text(source.style),
      gender: text(source.gender),
      age: text(source.age),
      tags: Array.isArray(source.tags)
        ? source.tags.filter((value): value is string => typeof value === "string").map((value) => value.trim()).filter(Boolean).slice(0, 30)
        : [],
      occupation,
      author_character_profile: characterProfile,
      world_era: text(source.world_era),
      modern_setting_compatible: source.modern_setting_compatible === true,
      time_travel_explicit: source.time_travel_explicit === true,
      author_schedule_brief: text(source.schedule_description),
      existing_author_schedules: Array.isArray(source.existing_author_schedules)
        ? source.existing_author_schedules.slice(0, 50).map((value) => {
          const row = isRecord(value) ? value : {};
          return {
            weekday: row.weekday ?? null,
            day_type: text(row.day_type),
            start_time: text(row.start_time),
            end_time: text(row.end_time),
            location_key: text(row.location_key),
            activity: text(row.activity),
          };
        })
        : [],
      author_private_context: privateContext.promptText,
    };
  });
  const system = [
    "你是 POYOZZ 的角色行程規劃器。一次為提供的 1 至 10 個公開角色整理可驗證的城市地圖行程。",
    "必須讀取角色名稱、稱號、職業、身分、世界觀、種族、性格、興趣、標籤、作者行程說明及 existing_author_schedules。existing_author_schedules 是作者已保存的固定時段與地點，必須原樣保留並視為優先限制，不得改寫或覆蓋；AI 只負責推演其餘空白時段。若 author_schedule_brief 為空，必須依角色卡設定推演合理日常，不可因此留白或標記無行程；若作者只提供部分時段，保留明確時段與限制，只補足空白，不得覆蓋作者設定。只使用輸入角色的設定與作者提供的行程方向，不可替角色創造與背景衝突的現代身分。歷史／古代角色若沒有作者明確設定現代相容或明確穿越，必須 placement=no_matching_location，不可放進現代城市地圖。奇幻種族只要背景明確相容現代世界，就可以正常安排。",
    "相似職業或場景必須共用 canonical location_key：酒吧老闆／酒保／酒吧員工共用 night-bar；企業主／主管／秘書共用 commercial；咖啡相關共用 cafe。不可為每個角色各造一個相似地點。",
    "可提出 shopping-street 作為新場景候選；即使本批只有一個角色也可保留，後端會跨批次統計公開角色數，達兩個不同角色才顯示新地標。相似場景需共用同一候選，不可輸出座標、圖片 URL、Storage path 或自行發明地標 ID。",
    "每天以整點為單位規劃。連續多小時在同一地點從事同一活動，合併為一個 start_time/end_time 區間；例如 09:00–17:00 的 8 小時工作必須留在同一地點。每個變體最多 4 個時段，可保留合理空檔。",
    "holiday 依台灣政府正式辦公日曆判斷，包含國定假日與補班日；不可單純把週末都視為假日。每個 weekday 變體權重固定 primary=80、alternative=20；每個 holiday 變體權重固定 primary=60、alternative=40。每個日型都必須提供 primary 與 alternative 兩套完整 24 小時行程，從 00:00 開始至次日 00:00 結束，時段必須連續無空檔、不可重疊；允許合併連續相同地點／活動的時段，但不得遺漏任何小時。",
    "special_events 可選擇輸出 0–4 個條件式節日行程，只能使用 event_key: taiwan_public_holiday、lunar_new_year、valentines_day、christmas。taiwan_public_holiday 代表台灣政府正式放假日；lunar_new_year 代表農曆除夕與春節假期；valentines_day 為每年 02-14；christmas 為每年 12-25。只有角色背景、關係或職業確實適合節日變化時才輸出，不要為每個角色硬加節日活動；若 placement=no_matching_location，special_events 必須是空陣列。每個特殊節日包含 event_key、event_name、slots；slots 同樣必須完整覆蓋 24 小時、2–4 個時段，並遵守一般時段的場景、招呼與雨備規範。角色生日目前沒有結構化日期來源，不可自行推算或輸出 birthday.",
    "戶外時段必須提供雨天室內替代地點、活動與一段 150–300 字元的 rain_fallback_greeting；室內時段所有 rain_fallback 欄位必須為 null。park 與 shopping-street 為戶外；其餘提供的地點為室內。",
    "作者行程說明只供內部規劃，輸出活動必須使用公開可見、簡短自然的描述，不得逐字複製整段說明或揭露私人情節。每個時段都要產生一段與該角色、地點、活動吻合的預生成招呼 encounter_greeting，長度 150–300 字元；不得直接揭露作者私密設定或照抄私密內容。",
    "每個 modern_map 角色還必須額外產生 relationship_greetings：依 hostile、dislike、wary、first_meeting、acquaintance、close、intimate、special 八種關係階段，各提供 3–5 段不同的繁體中文開場招呼，每段 150–300 字元。每段要符合角色個性，但不要寫死地點、日期或時間，因為實際場景由玩家遇見時的排程決定；同一階段內不得重複。階段語氣要有明顯差異：hostile 敵意、dislike 冷淡、wary 戒備、first_meeting 初識、acquaintance 熟悉、close 信任親近、intimate 深厚親密（不預設一定是戀愛）、special 特別且高度個人化。不可因關係階段而捏造玩家曾做過的事。",

    "只可使用 location_key: airport, commercial, night-bar, live-house, apartment, department-store, bookstore, cafe, park, shopping-street。場景類別不明或角色無現代地圖相容地點時，使用 no_matching_location 並回傳空 variants。",
    "輸出必須是嚴格 JSON object，唯一根欄位 characters。每個角色欄位為 character_id, placement, variants, special_events；modern_map 角色必須包含 relationship_greetings，no_matching_location 角色可省略。relationship_greetings 必須且只能包含八個 stage key，每個 key 對應 3–5 段 150–300 字元的字串陣列。variants 只包含 weekday 與 holiday；各自為兩個 variant 物件。variant 物件欄位為 variant_key, weight, slots。special_events 為 0–4 個 event_key, event_name, slots 物件的陣列；無適合節日時輸出空陣列。slot 欄位為 start_time, end_time, location_key, activity, is_outdoor, rain_fallback_location_key, rain_fallback_activity, rain_fallback_greeting, encounter_greeting。不可輸出額外欄位或 Markdown。",
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
  if (new Set(sources.map((source) => source.character_id)).size !== sources.length) {
    return { ok: false, characters: [], errors: ["source_character_ids_not_unique"] };
  }
  const sourceById = new Map(sources.map((source) => [source.character_id, source]));
  if (parsed.characters.length !== sources.length) errors.push("character_count_mismatch");
  const seen = new Set<string>();
  const characters: GeneratedCharacterSchedule[] = [];
  for (const item of parsed.characters) {
    if (!isRecord(item) ||
      !["character_id", "placement", "variants"].every((key) => Object.prototype.hasOwnProperty.call(item, key)) ||
      Object.keys(item).some((key) => !["character_id", "placement", "variants", "special_events", "relationship_greetings"].includes(key)) ||
      !isUuid(item.character_id)) {
      errors.push("character_item_invalid");
      continue;
    }
    const rawSpecialEvents = item.special_events === undefined ? [] : item.special_events;
    if (!Array.isArray(rawSpecialEvents) || rawSpecialEvents.length > 4) {
      errors.push("special_events_invalid");
      continue;
    }
    const specialEvents = rawSpecialEvents.map((event, index) =>
      validateSpecialEvent(event, errors, String(item.character_id) + "_special_event_" + index)
    ).filter((event): event is SpecialEventSchedule => event !== null);
    if (new Set(specialEvents.map((event) => event.event_key)).size !== specialEvents.length) {
      errors.push(String(item.character_id) + "_special_event_duplicate");
    }
    const id = item.character_id;
    const source = sourceById.get(id);
    if (!source || source.visibility !== "public" || source.deleted_at != null || seen.has(id)) {
      errors.push("character_identity_duplicate_or_unknown");
      continue;
    }
    seen.add(id);
    if (item.placement === "no_matching_location") {
      if (!hasExactKeys(item.variants, ["weekday", "holiday"]) ||
        !Array.isArray(item.variants.weekday) || item.variants.weekday.length !== 0 ||
        !Array.isArray(item.variants.holiday) || item.variants.holiday.length !== 0 ||
        specialEvents.length !== 0) {
        errors.push(id + "_no_location_variants_must_be_empty");
      }
      characters.push({
        character_id: id, placement: "no_matching_location",
        variants: { weekday: [], holiday: [] }, special_events: [],
      });
      continue;
    }
    if (item.placement !== "modern_map" || !isEncounterModernMapCompatible(source)) {
      errors.push(id + "_modern_map_placement_not_allowed");
      continue;
    }
    const relationshipGreetings = validateRelationshipGreetingPools(
      item.relationship_greetings,
      errors,
      id,
    );
    if (!relationshipGreetings) continue;
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
      characters.push({
        character_id: id, placement: "modern_map", variants: { weekday, holiday },
        special_events: specialEvents, relationship_greetings: relationshipGreetings,
      });
    }
  }

  // Preserve a candidate scene even when only one character is in this AI batch.
  // The database scene registry decides whether the marker is publicly visible by
  // counting distinct eligible characters across all published schedules, including
  // characters published by earlier batches. The model never supplies coordinates.

  if (seen.size !== sources.length) errors.push("character_coverage_incomplete");
  return { ok: errors.length === 0, characters: errors.length === 0 ? characters : [], errors: [...new Set(errors)] };
}
