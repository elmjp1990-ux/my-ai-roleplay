import { preparePrivateContext } from "./private-context-guard.ts";

export const ENCOUNTER_SCHEDULE_BATCH_LIMIT = 2147483647;
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
  "night-market", "restaurant", "university", "hospital", "gym", "cinema",
  "museum", "hotel", "train-station", "library", "theater", "art-gallery",
  "community-center", "music-studio", "bakery", "coworking-space",
] as const;

export const ENCOUNTER_DYNAMIC_SCENE_KEYS = [
  "shopping-street", "night-market", "restaurant", "university", "hospital",
  "gym", "cinema", "museum", "hotel", "train-station", "library", "theater",
  "art-gallery", "community-center", "music-studio", "bakery", "coworking-space",
] as const;


const OUTDOOR_SCENE_KEYS = new Set(["park", "shopping-street", "night-market"]);
const RAIN_FALLBACK_SCENE_KEYS = new Set([
  "airport", "commercial", "night-bar", "live-house", "apartment",
  "department-store", "bookstore", "cafe",
]);
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
  夜市: "night-market", 夜間市集: "night-market", "night market": "night-market",
  餐廳: "restaurant", 飯店餐廳: "restaurant", 餐館: "restaurant",
  大學: "university", 學校: "university", 校園: "university",
  醫院: "hospital", 診所: "hospital",
  健身房: "gym", 健身中心: "gym",
  電影院: "cinema", 影城: "cinema",
  博物館: "museum", 美術館: "museum", 展覽館: "museum",
  飯店: "hotel", 旅館: "hotel",
  車站: "train-station", 火車站: "train-station", 捷運站: "train-station", 高鐵站: "train-station", "train station": "train-station",
  圖書館: "library",
  劇院: "theater", 劇場: "theater",
  藝廊: "art-gallery", 畫廊: "art-gallery", "art gallery": "art-gallery",
  社區中心: "community-center", 活動中心: "community-center", "community center": "community-center",
  音樂工作室: "music-studio", 錄音室: "music-studio", "music studio": "music-studio",
  麵包店: "bakery", 烘焙坊: "bakery",
  共享辦公室: "coworking-space", 共同工作空間: "coworking-space", "co-working space": "coworking-space", "coworking space": "coworking-space",
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
export type GeneratedSceneMetadata = {
  location_key: typeof ENCOUNTER_SCENE_KEYS[number];
  display_name: string;
  icon: string;
  heading: string;
  description: string;
  event_label: string;
  event_title: string;
  event_description: string;
};

export type EncounterSceneCatalogEntry = {
  location_key: string;
  display_name?: string;
  is_dynamic?: boolean;
};

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

function isAirportUseReasonable(source: EncounterScheduleSource, activity: string): boolean {
  const profile = isRecord(source.personality_profile) ? source.personality_profile : {};
  const context = [
    text(source.name), text(source.title), text(source.occupation), text(source.intro),
    text(source.schedule_description), text(source.race), JSON.stringify(profile),
  ].join(" ");
  const airportRole = /機場|航空|機師|飛行員|空服|地勤|航務|機組|航空公司|airport|airline|pilot|flight attendant/i.test(context);
  const explicitTravel = /出差|出國|旅遊|旅行|搭機|飛機|機票|航班|接機|送機|轉機|候機|登機|出境|入境|travel|flight|boarding/i.test(context);
  const activityReason = /搭機|接機|送機|轉機|候機|航班|飛行|登機|出入境|機場勤務|航空|flight|boarding|departure|arrival/i.test(activity);
  return airportRole || (explicitTravel && activityReason);
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
    if (!rainLocation || !RAIN_FALLBACK_SCENE_KEYS.has(rainLocation) || !rainActivity || rainActivity.length > 200 ||
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

export function buildEncounterScheduleBatchMessages(
  sources: EncounterScheduleSource[],
  sceneCatalog: EncounterSceneCatalogEntry[] = [],
): {
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
  const existingDynamicScenes = sceneCatalog
    .filter((scene) => scene?.is_dynamic === true && normalizeEncounterSceneKey(scene.location_key))
    .map((scene) => ({
      location_key: normalizeEncounterSceneKey(scene.location_key),
      display_name: text(scene.display_name),
    }));
  const existingDynamicKeys = new Set(existingDynamicScenes.map((scene) => scene.location_key));
  const remainingDynamicSceneSlots = Math.max(0, 3 - existingDynamicKeys.size);
  const system = [
    "你是 POYOZZ 的角色行程規劃器。一次為佇列提供的所有公開角色整理可驗證的城市地圖行程；不得自行省略任何角色。",
    "必須讀取角色名稱、稱號、職業、身分、世界觀、種族、性格、興趣、標籤、作者行程說明及 existing_author_schedules。existing_author_schedules 是作者已保存的固定時段與地點，必須原樣保留並視為優先限制，不得改寫或覆蓋；AI 只負責推演其餘空白時段。若 author_schedule_brief 為空，必須依角色卡設定推演合理日常，不可因此留白或標記無行程；若作者只提供部分時段，保留明確時段與限制，只補足空白，不得覆蓋作者設定。只使用輸入角色的設定與作者提供的行程方向，不可替角色創造與背景衝突的現代身分。歷史／古代角色若沒有作者明確設定現代相容或明確穿越，必須 placement=no_matching_location，不可放進現代城市地圖。奇幻種族只要背景明確相容現代世界，就可以正常安排。",
    "相似職業或場景必須共用 canonical location_key：酒吧老闆／酒保／酒吧員工共用 night-bar；企業主／主管／秘書共用 commercial；咖啡相關共用 cafe；音樂演出者與樂迷可共用 live-house；一般交通轉乘優先使用 train-station。不可為每個角色各造一個相似地點。",
    "場景類型可依角色群體需求使用 shopping-street、night-market、restaurant、university、hospital、gym、cinema、museum、hotel、train-station、library、theater、art-gallery、community-center、music-studio、bakery、coworking-space。新增動態場景必須是多人有共同需求的合理公共場所；university 只適用學生／教職員或明確校園活動，hospital 只適用醫療工作／就診／探病，gym 需有運動或健身理由，museum／cinema／theater 等需符合角色興趣或明確活動；不得為了增加地標而硬塞角色。最多同時顯示 3 個動態地標；只有至少 2 位不同角色在本批次的主要行程共用同一個新動態場景，且尚有空位時，才能新增該場景。若沒有空位或本批次只有 1 位角色使用新場景，必須改用已存在且合理的靜態／動態地點；若沒有合適地點，使用 placement=no_matching_location，不可硬塞不相關場景或讓角色排入不會顯示的地點。雨天備案只能使用既有室內固定場景 key：airport、commercial、night-bar、live-house、apartment、department-store、bookstore、cafe。不可輸出座標、圖片 URL、Storage path 或自行發明地標 ID。",
    `目前已啟用的動態場景：${existingDynamicScenes.length ? JSON.stringify(existingDynamicScenes) : "目前沒有"}；本批次最多還能新增 ${remainingDynamicSceneSlots} 個動態地標。`,
    "airport 是特殊地點：只有角色本身職業／設定與航空機場有明確關聯，或作者設定有具體搭機、接送、轉機、出入境行程時才能使用。不得把機場當一般休閒、辦公或隨機偶遇地點；沒有明確理由時使用更合理的車站、商業大樓或其他場景。",
    "每天以整點為單位規劃。連續多小時在同一地點從事同一活動，合併為一個 start_time/end_time 區間；例如 09:00–17:00 的 8 小時工作必須留在同一地點。每個變體最多 4 個時段，可保留合理空檔。",
    "holiday 依台灣政府正式辦公日曆判斷，包含國定假日與補班日；不可單純把週末都視為假日。每個 weekday 變體權重固定 primary=80、alternative=20；每個 holiday 變體權重固定 primary=60、alternative=40。每個日型都必須提供 primary 與 alternative 兩套完整 24 小時行程，從 00:00 開始至次日 00:00 結束，時段必須連續無空檔、不可重疊；允許合併連續相同地點／活動的時段，但不得遺漏任何小時。",
    "special_events 可選擇輸出 0–4 個條件式節日行程，只能使用 event_key: taiwan_public_holiday、lunar_new_year、valentines_day、christmas。taiwan_public_holiday 代表台灣政府正式放假日；lunar_new_year 代表農曆除夕與春節假期；valentines_day 為每年 02-14；christmas 為每年 12-25。只有角色背景、關係或職業確實適合節日變化時才輸出，不要為每個角色硬加節日活動；若 placement=no_matching_location，special_events 必須是空陣列。每個特殊節日包含 event_key、event_name、slots；slots 同樣必須完整覆蓋 24 小時、2–4 個時段，並遵守一般時段的場景、招呼與雨備規範。角色生日目前沒有結構化日期來源，不可自行推算或輸出 birthday.",
    "戶外時段必須提供雨天室內替代地點、活動與一段 150–300 字元的 rain_fallback_greeting；室內時段所有 rain_fallback 欄位必須為 null。park、shopping-street 與 night-market 為戶外；其餘提供的地點為室內。",
    "作者行程說明只供內部規劃，輸出活動必須使用公開可見、簡短自然的描述，不得逐字複製整段說明或揭露私人情節。每個時段都要產生一段與該角色、地點、活動吻合的預生成招呼 encounter_greeting，長度 150–300 字元；不得直接揭露作者私密設定或照抄私密內容。",
    "每個 modern_map 角色還必須額外產生 relationship_greetings：依 hostile、dislike、wary、first_meeting、acquaintance、close、intimate、special 八種關係階段，各提供 3–5 段不同的繁體中文開場招呼，預設恰好 3 段（只有角色差異確實需要時才增加到 4–5 段），每段以 150–180 字元為目標且不得少於 150、不得超過 300 字元。每段要符合角色個性，但不要寫死地點、日期或時間，因為實際場景由玩家遇見時的排程決定；同一階段內不得重複。階段語氣要有明顯差異：hostile 敵意、dislike 冷淡、wary 戒備、first_meeting 初識、acquaintance 熟悉、close 信任親近、intimate 深厚親密（不預設一定是戀愛）、special 特別且高度個人化。不可因關係階段而捏造玩家曾做過的事。",

    "只可使用 location_key: airport, commercial, night-bar, live-house, apartment, department-store, bookstore, cafe, park, shopping-street, night-market, restaurant, university, hospital, gym, cinema, museum, hotel, train-station, library, theater, art-gallery, community-center, music-studio, bakery, coworking-space。場景類別不明或角色無現代地圖相容地點時，使用 no_matching_location 並回傳空 variants。",
    "scenes 必須為陣列，針對本批行程實際使用的每一個主要 location_key（不包含 rain_fallback_location_key）各產生一筆場景資料，包含 location_key, display_name, icon, heading, description, event_label, event_title, event_description。description 應為約 40–220 字的具體場景簡介；event_label 使用「最新消息」或合適公告分類；event_title 與 event_description 分別提供兩則簡短、符合角色世界觀的虛構場景消息，不得冒充真實活動或真實營業資訊；內容不要自行加 📣 等 emoji 前綴，畫面會統一加上公告圖示。不要把「目前沒有角色」寫進簡介，角色數量由系統即時顯示。",
    "輸出必須是嚴格 JSON object，根欄位 characters 與 scenes。每個角色欄位為 character_id, placement, variants, special_events；modern_map 角色必須包含 relationship_greetings，no_matching_location 角色可省略。relationship_greetings 必須且只能包含八個 stage key，每個 key 對應 3–5 段 150–300 字元的字串陣列。variants 只包含 weekday 與 holiday；各自為兩個 variant 物件。variant 物件欄位為 variant_key, weight, slots。special_events 為 0–4 個 event_key, event_name, slots 物件的陣列；無適合節日時輸出空陣列。slot 欄位為 start_time, end_time, location_key, activity, is_outdoor, rain_fallback_location_key, rain_fallback_activity, rain_fallback_greeting, encounter_greeting。scenes 只包含上述八個欄位。不可輸出額外欄位或 Markdown。",
  ].join("\n");
  return {
    messages: [
      { role: "system", content: system },
      { role: "user", content: JSON.stringify({
        characters: promptSources,
        scene_catalog: sceneCatalog.map((scene) => ({
          location_key: normalizeEncounterSceneKey(scene.location_key),
          display_name: text(scene.display_name),
          is_dynamic: scene.is_dynamic === true,
        })),
      }) },
    ],
    protectedContextByCharacter,
  };
}

export function parseEncounterScheduleBatchOutput(
  raw: string,
  sources: EncounterScheduleSource[],
  sceneCatalog: EncounterSceneCatalogEntry[] = [],
): { ok: boolean; characters: GeneratedCharacterSchedule[]; scenes: GeneratedSceneMetadata[]; errors: string[] } {
  const errors: string[] = [];
  let parsed: unknown;
  try { parsed = JSON.parse(String(raw ?? "")); } catch { return { ok: false, characters: [], scenes: [], errors: ["output_json_invalid"] }; }
  if (!isRecord(parsed) || !Array.isArray(parsed.characters) ||
    Object.keys(parsed).some((key) => !["characters", "scenes"].includes(key))) {
    return { ok: false, characters: [], scenes: [], errors: ["output_root_invalid"] };
  }
  if (new Set(sources.map((source) => source.character_id)).size !== sources.length) {
    return { ok: false, characters: [], scenes: [], errors: ["source_character_ids_not_unique"] };
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
    const scheduleSlots = [...weekday, ...holiday].flatMap((variant) => variant.slots)
      .concat(specialEvents.flatMap((event) => event.slots));
    if (scheduleSlots.some((slot) =>
      (slot.location_key === "airport" || slot.rain_fallback_location_key === "airport") &&
      !isAirportUseReasonable(source, slot.activity))) {
      errors.push(id + "_airport_location_without_character_context");
    }
    if (weekday.length === 2 && holiday.length === 2) {
      characters.push({
        character_id: id, placement: "modern_map", variants: { weekday, holiday },
        special_events: specialEvents, relationship_greetings: relationshipGreetings,
      });
    }
  }

  // New dynamic locations must be shared by at least two characters in this batch.
  // The scene catalog tells the model which dynamic markers already exist and how
  // many of the three server-controlled marker slots remain.
  const usedSceneKeys = new Set<string>();
  const primarySceneCharacters = new Map<string, Set<string>>();
  for (const character of characters) {
    for (const variant of [...character.variants.weekday, ...character.variants.holiday]) {
      for (const slot of variant.slots) {
        usedSceneKeys.add(slot.location_key);
        const ids = primarySceneCharacters.get(slot.location_key) || new Set<string>();
        ids.add(character.character_id);
        primarySceneCharacters.set(slot.location_key, ids);
      }
    }
    for (const event of character.special_events) {
      for (const slot of event.slots) {
        usedSceneKeys.add(slot.location_key);
        const ids = primarySceneCharacters.get(slot.location_key) || new Set<string>();
        ids.add(character.character_id);
        primarySceneCharacters.set(slot.location_key, ids);
      }
    }
  }
  const existingDynamicKeys = new Set(
    sceneCatalog.filter((scene) => scene?.is_dynamic === true)
      .map((scene) => normalizeEncounterSceneKey(scene.location_key))
      .filter((key): key is string => key !== null),
  );
  const newDynamicKeys = [...primarySceneCharacters.keys()].filter((key) =>
    (ENCOUNTER_DYNAMIC_SCENE_KEYS as readonly string[]).includes(key) && !existingDynamicKeys.has(key)
  );
  for (const key of newDynamicKeys) {
    if ((primarySceneCharacters.get(key)?.size || 0) < 2) {
      errors.push("dynamic_scene_requires_two_batch_characters_" + key);
    }
  }
  if (existingDynamicKeys.size + newDynamicKeys.length > 3) {
    errors.push("dynamic_scene_marker_limit_exceeded");
  }

  const rawScenes = parsed.scenes === undefined ? [] : parsed.scenes;
  const scenes: GeneratedSceneMetadata[] = [];
  if (!Array.isArray(rawScenes) || rawScenes.length > ENCOUNTER_SCENE_KEYS.length) {
    errors.push("scene_metadata_array_invalid");
  } else {
    const seenScenes = new Set<string>();
    for (const rawScene of rawScenes) {
      if (!hasExactKeys(rawScene, [
        "location_key", "display_name", "icon", "heading", "description",
        "event_label", "event_title", "event_description",
      ])) {
        errors.push("scene_metadata_shape_invalid");
        continue;
      }
      const locationKey = normalizeEncounterSceneKey(rawScene.location_key);
      const displayName = text(rawScene.display_name);
      const icon = text(rawScene.icon);
      const heading = text(rawScene.heading);
      const description = text(rawScene.description);
      const eventLabel = text(rawScene.event_label);
      const eventTitle = text(rawScene.event_title);
      const eventDescription = text(rawScene.event_description);
      if (!locationKey || !usedSceneKeys.has(locationKey) || seenScenes.has(locationKey) ||
        Array.from(displayName).length < 1 || Array.from(displayName).length > 32 ||
        Array.from(icon).length < 1 || Array.from(icon).length > 4 || /[<>]/.test(icon) ||
        Array.from(heading).length < 2 || Array.from(heading).length > 50 ||
        Array.from(description).length < 30 || Array.from(description).length > 500 ||
        Array.from(eventLabel).length < 2 || Array.from(eventLabel).length > 20 ||
        Array.from(eventTitle).length < 2 || Array.from(eventTitle).length > 80 ||
        Array.from(eventDescription).length < 2 || Array.from(eventDescription).length > 160) {
        errors.push("scene_metadata_value_invalid");
        continue;
      }
      seenScenes.add(locationKey);
      scenes.push({
        location_key: locationKey as GeneratedSceneMetadata["location_key"],
        display_name: displayName, icon, heading, description,
        event_label: eventLabel, event_title: eventTitle, event_description: eventDescription,
      });
    }
  }
  for (const key of usedSceneKeys) {
    if (!scenes.some((scene) => scene.location_key === key)) {
      errors.push((ENCOUNTER_DYNAMIC_SCENE_KEYS as readonly string[]).includes(key)
        ? "dynamic_scene_metadata_missing_" + key
        : "scene_metadata_missing_" + key);
    }
  }

  if (seen.size !== sources.length) errors.push("character_coverage_incomplete");
  return {
    ok: errors.length === 0,
    characters: errors.length === 0 ? characters : [],
    scenes: errors.length === 0 ? scenes : [],
    errors: [...new Set(errors)],
  };
}
