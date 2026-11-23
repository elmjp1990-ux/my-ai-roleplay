import { preparePrivateContext } from "./private-context-guard.ts";

export const ENCOUNTER_SCHEDULE_BATCH_LIMIT = 2147483647;
export const ENCOUNTER_SCHEDULE_VARIANT_WEIGHTS = {
  weekday: { primary: 80, alternative: 20 },
  holiday: { primary: 60, alternative: 40 },
} as const;
export const ENCOUNTER_SCHEDULE_MAX_SLOTS_PER_VARIANT = 4;
export const ENCOUNTER_SCHEDULE_MAX_HOURLY_BLOCKS_PER_DAY = 24;

export const ENCOUNTER_SPECIAL_EVENT_KEYS = [
  "taiwan_public_holiday", "lunar_new_year", "valentines_day", "christmas",
] as const;

export const ENCOUNTER_SCENE_KEYS = [
  "waterfront", "commercial", "airport", "university", "park",
  "shopping-street", "department-store", "hospital", "night-bar", "live-house",
  "luxury-apartment", "apartment", "convenience-store", "private-club",
] as const;

// Scene anchors are fixed A–N map locations. Dynamic content belongs inside
// these locations and must never create additional map markers.
export const ENCOUNTER_DYNAMIC_SCENE_KEYS = [] as const;

const OUTDOOR_SCENE_KEYS = new Set(["waterfront", "park", "shopping-street"]);
const MODERN_SETTING_PATTERN = /現代世界|現代背景|現代都市|現代社會|現代生活|當代|財閥|企業集團|集團總裁|總裁夫人|企業|公司|商業盟約|慈善晚宴|時尚雜誌|名媛|豪門|媒體|智慧型手機|手機通訊|社群媒體|網路平台|科技業|捷運|地鐵|高鐵|信用卡|電子商務|藝術工作室|私人美術館|上班族|辦公室|公司職員|大學校園|現代醫院|現代學校|手機|網路|社群|公寓|都市|城市生活|地下\s*Live\s*House|Live\s*House|地下樂團|地下搖滾|搖滾樂團|獨立樂團|樂團主唱|主吉他手|吉他手|貝斯手|鼓手|練團室|錄音室|效果器|重機|機車|出租屋|頂樓出租屋|租屋處|宵夜攤|冰美式|試音|樂器行|男公關|牛郎|夜生活|俱樂部|VIP|黑卡|live\s*music|rock\s*band|guitarist|bassist|drummer|motorcycle|rented\s*apartment/i;
const CULTIVATION_PATTERN = /修仙|仙俠|修真|修煉|靈根|金丹|元嬰|渡劫|宗門|仙界|魔界|靈氣|劍修|丹修|道君|仙尊|cultivation|xianxia|xianxia/i;
const HISTORICAL_PATTERN = /ancient|historical|medieval|antiquity|古代|歷史|中世紀|中古|封建|戰國|春秋|秦漢|唐代|宋代|明代|清代|古羅馬|古希臘|大正時代|維多利亞時代/i;
const SCI_FI_PATTERN = /科幻|未來世界|未來都市|星際|太空殖民|賽博龐克|賽博|機甲|人工智慧統治|星球聯邦|science fiction|sci-fi|cyberpunk/i;
const APOCALYPSE_PATTERN = /末日|喪屍|殭屍病毒|核戰後|廢土|災後世界|末世|post-apocalyptic|apocalypse/i;
const FANTASY_PATTERN = /奇幻|魔法|魔法世界|精靈王國|龍族|魔物|異世界|魔王|勇者|fantasy|mythic/i;
const ALTERNATE_PATTERN = /架空世界|架空王國|虛構王國|平行世界|異世界/i;
const SUPERNATURAL_SPECIES_PATTERN = /吸血鬼|狼人|精靈|天使|惡魔|人魚|龍族|妖精|獸人|vampire|werewolf|elf|elves|angel|demon|mermaid|dragon/i;
const SCENE_DISPLAY_NAMES: Record<string, string> = {
  waterfront: "水岸港區", commercial: "辦公大樓", airport: "機場",
  university: "校園", park: "中央公園", "shopping-street": "商店街",
  "department-store": "百貨公司", hospital: "中央醫院", "night-bar": "夜間酒吧",
  "live-house": "展演空間", "luxury-apartment": "高級公寓", apartment: "308公寓",
  "convenience-store": "便利商店", "private-club": "高級會所",
};
const SCENE_ALIASES: Record<string, string> = {
  bar: "night-bar", pub: "night-bar", 酒吧: "night-bar", 酒館: "night-bar", 夜店: "night-bar", 夜間酒吧: "night-bar", 歸途: "night-bar",
  公司: "commercial", 代辦所: "commercial", 商辦: "commercial", 辦公大樓: "commercial", 辦公室: "commercial", 企業大樓: "commercial",
  機場: "airport", airport: "airport",
  公園: "park", 中央公園: "park", park: "park",
  公寓: "apartment", 住宅: "apartment", apartment: "apartment", 住所: "apartment", 客戶家: "apartment",
  高級公寓: "luxury-apartment", 豪宅: "luxury-apartment", 別墅: "luxury-apartment",
  livehouse: "live-house", "live house": "live-house", 現場音樂: "live-house", 音樂展演: "live-house", 展演廳: "live-house", 展演空間: "live-house",
  購物街: "shopping-street", 商店街: "shopping-street", 逛街商圈: "shopping-street", 街頭: "shopping-street", 街道: "shopping-street", "night-market": "shopping-street", "夜市": "shopping-street",
  咖啡店: "shopping-street", 咖啡廳: "shopping-street", cafe: "shopping-street", 書店: "shopping-street", bookstore: "shopping-street",
  二手樂器行: "shopping-street", 樂器行: "shopping-street", 樂器店: "shopping-street",
  花店: "shopping-street", 路邊攤: "shopping-street", 小吃攤: "shopping-street", 小吃店: "shopping-street",
  百貨: "department-store", 百貨公司: "department-store", department: "department-store", restaurant: "department-store", 餐廳: "department-store", 餐館: "department-store",
  大學: "university", 學校: "university", 校園: "university", university: "university",
  醫院: "hospital", 中央醫院: "hospital", 診所: "hospital",
  便利商店: "convenience-store", 超商: "convenience-store", convenience: "convenience-store",
  江邊堤防: "waterfront", 河堤: "waterfront", 河岸: "waterfront", 水岸港區: "waterfront", 海港: "waterfront",
  高級會所: "private-club", 私人會所: "private-club", privateclub: "private-club",
};

type RecordValue = Record<string, unknown>;
type ScheduleSlot = {
  start_time: string;
  end_time: string;
  location_key: string | null;
  location_description: string;
  activity: string;
  scene_description: string;
  is_outdoor: boolean;
  rain_fallback_location_key: string | null;
  rain_fallback_activity: string | null;
  rain_fallback_greeting: string | null;
  encounter_greeting: string | null;
};
type ScheduleVariant = {
  variant_key: "primary" | "alternative";
  weight: number;
  slots: ScheduleSlot[];
};
type ScheduleOption = Omit<ScheduleSlot, "start_time" | "end_time"> & {
  option_key: "option_1" | "option_2" | "option_3";
  weight: number;
};
type ScheduleTimeBlock = {
  start_time: string;
  end_time: string;  options: ScheduleOption[];
};
type SpecialEventSchedule = {
  event_key: typeof ENCOUNTER_SPECIAL_EVENT_KEYS[number];
  event_name: string;
  slots: ScheduleSlot[];
};
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
    weekday: ScheduleTimeBlock[];
    holiday: ScheduleTimeBlock[];
  };
  special_events: SpecialEventSchedule[];
};
export type EncounterScheduleSource = RecordValue & {
  character_id: string;
  author_id: string;
};

const isRecord = (value: unknown): value is RecordValue =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const text = (value: unknown): string => typeof value === "string" ? value.trim() : "";
const isValidEncounterLocationLabel = (value: string): boolean => {
  const label = value.trim().normalize("NFKC");
  const characterCount = Array.from(label.replace(/\s/g, "")).length;
  return characterCount > 0 && characterCount <= 20 && !/[或、／\\/|，,;；]/.test(label);
};
const isUuid = (value: unknown): value is string =>
  typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const hasExactKeys = (value: unknown, keys: readonly string[]): value is RecordValue =>
  isRecord(value) && Object.keys(value).length === keys.length &&
  keys.every((key) => Object.prototype.hasOwnProperty.call(value, key));

export type EncounterActivitySpace = "indoor" | "outdoor" | "vehicle";

/**
 * Activity space is inferred independently from the display location.
 * A vehicle is not outdoors for weather purposes, but remains distinct from
 * an indoor room so its street-side display location is not rewritten.
 */
export function classifyEncounterActivitySpace(
  activityValue: unknown,
  locationValue: unknown = "",
  requestedOutdoor = false,
): EncounterActivitySpace {
  const activity = text(activityValue).normalize("NFKC");
  const location = text(locationValue).normalize("NFKC");
  if (/計程車|計程車內|車內|車上|車廂|車裡|車中|搭車|乘車|駕車|開車|副駕|後座/.test(activity)) {
    return "vehicle";
  }
  // Product rule: smoking on the character's apartment balcony is treated as
  // part of the apartment's indoor scene, not as a weather-exposed activity.
  if (/陽台/.test(activity) && /抽菸|吸菸|抽煙/.test(activity)) return "indoor";

  const clearlyIndoor = /室內|家中|家裡|公寓裡|客戶家|客戶住處|修理電燈|組裝書架|搬家打包|除蟲|清理雜物|包廂|晚宴|家庭聚餐|吃午餐|吃早餐|吃晚餐|用餐|超商內|貨架前|店內|結帳|選購飲料|挑選飲料|購物/.test(activity);
  if (clearlyIndoor) return "indoor";

  const clearlyOutdoor = /站在騎樓下|餐廳門口|店外|門外|外面等車|在門口|在街頭|街頭道別|街道上|站在路邊|在路邊|在街上|公園步道|戶外|沿著.{0,8}步道|下車後|走出車外|走出車門|下車道別|在路上散步/.test(activity);
  if (clearlyOutdoor) return "outdoor";

  const indoorLocation = /^(客戶家|客戶住處|住所|住家|公寓|餐廳|餐館|小吃店|超商|便利商店|代辦所|公司|辦公室|咖啡廳|書店|百貨公司)$/i.test(location);
  if (indoorLocation) return "indoor";
  return requestedOutdoor ? "outdoor" : "indoor";
}

function collectAllTextValues(value: unknown, depth = 0): string[] {
  if (depth > 6 || value == null) return [];
  if (typeof value === "string" || typeof value === "number") return [String(value)];
  if (Array.isArray(value)) return value.flatMap((item) => collectAllTextValues(item, depth + 1));
  if (!isRecord(value)) return [];
  return Object.values(value).flatMap((nested) => collectAllTextValues(nested, depth + 1));
}

function collectResidentialProfileContext(value: unknown, depth = 0): string[] {
  if (depth > 5 || !isRecord(value)) return [];
  const values: string[] = [];
  for (const [key, nested] of Object.entries(value)) {
    if (/(residen|housing|living_environment|home_environment|居住|住所|住處|住宅|生活環境|家庭環境)/i.test(key)) {
      values.push(...collectAllTextValues(nested));
    } else if (isRecord(nested)) {
      values.push(...collectResidentialProfileContext(nested, depth + 1));
    }
  }
  return values;
}

function hasExplicitLuxuryResidenceContext(value: unknown): boolean {
  const context = text(value).normalize("NFKC").replace(/\s+/g, "");
  return /(高級公寓|豪華公寓|豪宅|別墅|莊園|頂樓豪宅|頂級住宅|penthouse|mansion|villa|estate)/i.test(context);
}

export function normalizeEncounterSceneKey(
  value: unknown,
  activityValue: unknown = "",
  characterResidentialContext: unknown = "",
): string | null {
  const original = text(value).normalize("NFKC");
  const raw = original.toLocaleLowerCase();
  const compact = raw.replace(/\s+/g, "");
  const activity = text(activityValue).normalize("NFKC");
  const context = (original + " " + activity).toLocaleLowerCase().replace(/\s+/g, "");

  // Customer-home classification depends on the customer's explicit home
  // description, not on the character's own residence profile.
  const luxuryResidencePattern = /(豪宅|別墅|莊園|豪華住宅|高級住宅|頂級住宅|豪華公寓|高級公寓|頂樓豪宅|penthouse|mansion|villa|estate)/i;
  if (/客戶家/.test(compact) && luxuryResidencePattern.test(activity)) {
    return "luxury-apartment";
  }

  // Canonical keys and exact aliases are authoritative destination labels.
  // Resolve them before generic residence heuristics and activity inference.
  if ((ENCOUNTER_SCENE_KEYS as readonly string[]).includes(raw)) return raw;
  const exactAlias = SCENE_ALIASES[raw] || SCENE_ALIASES[original];
  if (exactAlias) return exactAlias;

  // Generic rooms use K only when the character's own residence is explicitly
  // identified as luxury; otherwise ordinary residential labels resolve to L.
  if (luxuryResidencePattern.test(compact)) return "luxury-apartment";
  if (/(臥室|臥房|客廳|書房|廚房|陽台|房間|房內|bedroom|livingroom|studyroom|kitchen|balcony)/i.test(compact) &&
      hasExplicitLuxuryResidenceContext(characterResidentialContext)) {
    return "luxury-apartment";
  }
  if (/(308公寓|頂樓加蓋|頂樓出租屋|頂樓套房|公寓|住宅|住家|住所|家中|家裡|租屋|租屋處|出租屋|套房|臥室|臥房|客廳|書房|廚房|陽台|房間|房內|宿舍|bedroom|apartment|rented\\s*room)/i.test(compact)) {
    return "apartment";
  }

  // Explicit fixed destinations take precedence over incidental activity keywords.
  if (/(夜間酒吧|酒吧|酒館|夜店|歸途)/i.test(compact)) return "night-bar";
  if (/(高級會所|私人會所|高級俱樂部|私人俱樂部)/i.test(compact)) return "private-club";
  if (/(便利商店|超商)/i.test(compact)) return "convenience-store";
  if (/(江邊堤防|河堤|河岸|水岸|海港|港區)/i.test(compact)) return "waterfront";
  if (/(中央醫院|醫院|診所)/i.test(compact)) return "hospital";
  if (/(校園|大學|學校)/i.test(compact)) return "university";
  if (/(百貨公司|百貨|餐廳|餐館)/i.test(compact)) return "department-store";
  if (/(商業大樓|辦公大樓|公司|代辦所|辦公室|企業大樓)/i.test(compact)) return "commercial";
  if (/(便利商店|超商|咖啡廳|咖啡店|書店|二手樂器行|樂器行|樂器店|花店|路邊攤|小吃攤|小吃店|商店街|購物街)/i.test(compact)) return "shopping-street";

  // Named performance venues and rehearsal spaces use J; a night bar explicitly
  // named above stays at I even when the activity mentions a band or live music.
  if (/(live[\s-]*house|livehouse|練團室|排練室|彩排室|錄音室|音樂工作室|音樂展演|現場音樂|展演廳|展演空間)/i.test(compact)) {
    return "live-house";
  }

  // A generic alley after a show belongs to the Live House event context;
  // an ordinary alley remains part of the existing street scene.
  if (/(後巷|巷弄|巷口|街角)/i.test(compact)) {
    if (/(散場|演出結束|表演結束|演出後|表演後|演唱會後|演出完|表演完|收拾器材|搬器材|樂團聚會|演出|表演|團練|練團|排練|彩排)/i.test(context)) {
      return "live-house";
    }
    return "shopping-street";
  }

  // Street-side food stalls and small neighborhood eateries share fixed scene F.
  if (/(路邊攤|小吃攤|攤販|早餐店|便當店|麵店|食堂)/i.test(compact)) return "shopping-street";
  if (/(人行道|路邊|街道|街頭)/i.test(compact)) return "shopping-street";

  // For generic or otherwise unmapped places, music and performance context
  // can select the Live House background. A residential or explicit shop label
  // above always takes precedence.
  if (/(live[\s-]*house|livehouse|音樂|樂團|團練|練團|排練|彩排|表演|演出|舞台|樂器|吉他|貝斯|鼓手|主唱|錄音室|音樂工作室|散場|演出結束|表演結束|演出後|表演後|演唱會後|演出完|表演完|收拾器材|搬器材|樂團聚會|music|band|guitar|bass|drummer|performance|rehearsal)/i.test(context)) {
    return "live-house";
  }

  return null;
}

const SLEEPING_SCHEDULE_PATTERN = /熟睡|沉睡|酣睡|安睡|睡著|睡着|睡覺|睡眠|睡夢|睡得很沉|淺眠|深層睡眠|入睡|睡去|午睡|補眠|就寢/;

export function resolveEncounterScheduleAvailability(
  activity: unknown,
  sceneDescription: unknown = "",
): "available" | "sleeping" {
  const context = [text(activity), text(sceneDescription)].join(" ").normalize("NFKC")
    .replace(/準備(?:要)?睡覺/g, "");
  return SLEEPING_SCHEDULE_PATTERN.test(context) ? "sleeping" : "available";
}

export type EncounterWorldviewCategory =
  | "modern" | "modern_fantasy" | "historical" | "cultivation"
  | "fantasy" | "science_fiction" | "post_apocalyptic"
  | "alternate_world" | "unknown";

export type EncounterWorldviewClassification = {
  category: EncounterWorldviewCategory;
  modern_map_compatible: boolean;
  confidence: "high" | "low";
};

export function classifyEncounterWorldview(source: EncounterScheduleSource): EncounterWorldviewClassification {
  const profile = isRecord(source.personality_profile) ? source.personality_profile : {};
  const derivedProfile = isRecord(source.derived_character_profile) ? source.derived_character_profile : {};
  const derivedLifeContext = isRecord(source.derived_life_context) ? source.derived_life_context : {};
  const context = [
    text(source.world_era), text(source.setting_era), text(source.intro),
    text(source.title), text(source.occupation), text(source.race), text(source.style),
    ...(Array.isArray(source.tags) ? source.tags.filter((value): value is string => typeof value === "string") : []),
    text(source.schedule_description), text(source.private_info),
    JSON.stringify(profile), JSON.stringify(derivedProfile), JSON.stringify(derivedLifeContext),
  ].join(" ");
  const modern = source.modern_setting_compatible === true || source.time_travel_explicit === true || MODERN_SETTING_PATTERN.test(context);
  const cultivation = CULTIVATION_PATTERN.test(context);
  const historical = HISTORICAL_PATTERN.test(context);
  const scienceFiction = SCI_FI_PATTERN.test(context);
  const apocalypse = APOCALYPSE_PATTERN.test(context);
  const fantasy = FANTASY_PATTERN.test(context);
  const alternate = ALTERNATE_PATTERN.test(context);

  // Explicit contemporary context wins for modern supernatural species, but
  // explicit historical/cultivation eras remain excluded unless time travel is stated.
  if (source.time_travel_explicit === true) {
    return { category: "modern_fantasy", modern_map_compatible: true, confidence: "high" };
  }
  if (cultivation) return { category: "cultivation", modern_map_compatible: false, confidence: "high" };
  if (historical) return { category: "historical", modern_map_compatible: false, confidence: "high" };
  if (scienceFiction) return { category: "science_fiction", modern_map_compatible: false, confidence: "high" };
  if (apocalypse) return { category: "post_apocalyptic", modern_map_compatible: false, confidence: "high" };
  if (modern) return {
    category: (fantasy || SUPERNATURAL_SPECIES_PATTERN.test(context)) ? "modern_fantasy" : "modern",
    modern_map_compatible: true,
    confidence: "high",
  };
  // "異世界" is an alternate-world signal, not sufficient evidence of
  // conventional fantasy by itself; explicit magic/fantasy signals still win
  // only when no alternate-world marker is present.
  if (alternate) return { category: "alternate_world", modern_map_compatible: false, confidence: "high" };
  if (fantasy) return { category: "fantasy", modern_map_compatible: false, confidence: "high" };
  return { category: "unknown", modern_map_compatible: false, confidence: "low" };
}

export type EncounterWorldviewScheduleDisposition = "generate" | "not_applicable" | "needs_review";

export function getEncounterWorldviewScheduleDisposition(
  classification: EncounterWorldviewClassification,
  manualDecision: unknown = null,
): EncounterWorldviewScheduleDisposition {
  if (manualDecision === "modern_map_compatible") return "generate";
  if (classification.modern_map_compatible) return "generate";
  return classification.category === "unknown" ? "needs_review" : "not_applicable";
}

export function isEncounterModernMapCompatible(source: EncounterScheduleSource): boolean {
  return getEncounterWorldviewScheduleDisposition(
    classifyEncounterWorldview(source),
    source.worldview_review_decision,
  ) === "generate";
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
  const adjustedEnd = end <= start ? end + 1440 : end;  return adjustedEnd - start;
}

function intervalsOverlap(a: { start: number; end: number }, b: { start: number; end: number }): boolean {
  for (const offset of [-1440, 0, 1440]) {
    if (a.start < b.end + offset && b.start + offset < a.end) return true;
  }
  return false;
}

function validateHourlySchedule(
  value: unknown,
  errors: string[],
  label: string,
  characterResidentialContext: string,
): ScheduleTimeBlock[] | null {
  // Enforce weighted alternatives for every hour, not merely a daily minimum.
  if (!Array.isArray(value) || value.length !== 24) {
    errors.push(label + "_must_cover_24_hours");
    if (!Array.isArray(value)) return null;
  }
  const rawBlocks = Array.isArray(value) ? value : [];
  const blocks: ScheduleTimeBlock[] = [];
  for (let index = 0; index < rawBlocks.length; index++) {
    const rawBlock = rawBlocks[index];
    const blockLabel = label + "_hour_" + index;
    if (!hasExactKeys(rawBlock, ["start_time", "end_time", "options"])) {
      errors.push(blockLabel + "_keys_invalid");
      continue;
    }
    const start = parseHour(rawBlock.start_time);
    const end = parseHour(rawBlock.end_time);
    if (start === null || end === null || durationMinutes(start, end) !== 60) {
      errors.push(blockLabel + "_must_be_exactly_one_hour");
      continue;
    }
    if (!Array.isArray(rawBlock.options) || rawBlock.options.length < 2 || rawBlock.options.length > 3) {
      errors.push(blockLabel + "_options_count_invalid");
      continue;
    }
    let weightTotal = 0;
    const options: ScheduleOption[] = [];
    for (let optionIndex = 0; optionIndex < rawBlock.options.length; optionIndex++) {
      const rawOption = rawBlock.options[optionIndex];
      if (!hasExactKeys(rawOption, [
        "weight", "location", "activity", "is_outdoor",
        "rain_fallback_location", "rain_fallback_activity",
      ])) {
        errors.push(blockLabel + "_option_" + optionIndex + "_keys_invalid");
        continue;
      }
      const weight = rawOption.weight;
      if (!Number.isInteger(weight) || Number(weight) < 1 || Number(weight) > 100) {
        errors.push(blockLabel + "_option_" + optionIndex + "_weight_invalid");
        continue;
      }
      weightTotal += Number(weight);
      const locationDescription = text(rawOption.location);
      const activity = text(rawOption.activity);
      const locationKey = normalizeEncounterSceneKey(locationDescription, activity, characterResidentialContext);
      const activitySpace = classifyEncounterActivitySpace(activity, locationDescription, rawOption.is_outdoor === true);
      const isOutdoor = activitySpace === "outdoor";
      if (!isValidEncounterLocationLabel(locationDescription)) {
        errors.push(blockLabel + "_option_" + optionIndex + "_location_invalid");
      }
      if (Array.from(activity).length < 8 || Array.from(activity).length > 30) {
        errors.push(blockLabel + "_option_" + optionIndex + "_activity_length_invalid");
      }
      if (typeof rawOption.is_outdoor !== "boolean") {
        errors.push(blockLabel + "_option_" + optionIndex + "_outdoor_flag_invalid");
      }

      let rainLocationKey: string | null = null;
      let rainActivity: string | null = null;
      // Rain fallback fields are optional context only. Rain preference belongs to
      // the character; publishing must not constrain fallback location/content.
      const rainLocationDescription = text(rawOption.rain_fallback_location);
      rainLocationKey = rainLocationDescription
        ? normalizeEncounterSceneKey(rainLocationDescription, rawOption.rain_fallback_activity, characterResidentialContext)
        : null;
      rainActivity = text(rawOption.rain_fallback_activity) || null;
      options.push({
        option_key: ("option_" + (optionIndex + 1)) as ScheduleOption["option_key"],
        weight: Number(weight),
        location_key: locationKey,
        location_description: locationDescription,
        activity,
        // Keep the legacy DB field populated from the concise activity. The model
        // no longer generates a separate scene description or greeting paragraph.
        scene_description: activity,
        is_outdoor: isOutdoor,
        rain_fallback_location_key: rainLocationKey,
        rain_fallback_activity: rainActivity,
        rain_fallback_greeting: null,
        encounter_greeting: null,
      });
    }
    if (weightTotal !== 100) errors.push(blockLabel + "_option_weights_must_sum_100");
    if (options.length === rawBlock.options.length) {
      blocks.push({
        start_time: text(rawBlock.start_time),
        end_time: text(rawBlock.end_time),
        options,
      });
    }
  }
  if (blocks.length === 24) {
    for (let index = 0; index < 24; index++) {
      const expectedStart = String(index).padStart(2, "0") + ":00";
      const expectedEnd = String((index + 1) % 24).padStart(2, "0") + ":00";
      if (blocks[index].start_time !== expectedStart || blocks[index].end_time !== expectedEnd) {
        errors.push(label + "_must_be_contiguous_24_hour_day");
        break;
      }
    }
  }
   const ordered = blocks.slice().sort((a, b) => (parseHour(a.start_time) ?? 0) - (parseHour(b.start_time) ?? 0));
  for (let index = 1; index < ordered.length; index++) {
    const previousStart = parseHour(ordered[index - 1].start_time) ?? 0;
    const currentStart = parseHour(ordered[index].start_time) ?? 0;
    if (previousStart === currentStart || intervalsOverlap(
      { start: previousStart, end: previousStart + 60 },
      { start: currentStart, end: currentStart + 60 },
    )) errors.push(label + "_hourly_blocks_overlap");
  }
  return blocks;
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
      tags: Array.isArray(source.tags)        ? source.tags.filter((value): value is string => typeof value === "string").map((value) => value.trim()).filter(Boolean).slice(0, 30)
        : [],
      occupation,
      author_character_profile: characterProfile,
      character_ai_profile: isRecord(source.derived_character_profile) ? source.derived_character_profile : null,
      character_life_context: isRecord(source.derived_life_context) ? source.derived_life_context : null,
      world_era: text(source.world_era),
      modern_setting_compatible: isEncounterModernMapCompatible(source),
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
            location: text(row.location_description) ||
              SCENE_DISPLAY_NAMES[text(row.location_key)] || "",
            activity: text(row.activity),
          };
        })
        : [],
      author_private_context: privateContext.promptText,
    };
  });
  // Scene names are withheld from the model; matching remains system-side.
  void sceneCatalog;
  const system = [
    "你是 POYOZZ 的角色行程規劃器。一次為佇列提供的所有公開角色整理可驗證的城市地圖行程；不得自行省略任何角色。",
    "系統已先完成世界觀分類；本次送入的角色都已由系統判定為現代地圖相容。你不得重新判斷時代、世界觀或地圖資格，也不得輸出 no_matching_location。吸血鬼、狼人、精靈等種族不代表古代；依輸入角色的現代背景推演其日常。必須讀取角色名稱、稱號、職業、身分、世界觀、種族、性格、興趣、標籤、作者行程說明及 existing_author_schedules。existing_author_schedules 是作者已保存的固定時段與地點，必須原樣保留並視為最高優先限制，不得改寫或覆蓋；AI 只負責推演其餘時段。作者固定行程僅作為規劃限制。若 author_schedule_brief 為空，依角色卡設定推演合理日常；若作者只提供部分時段，保留明確時段與限制，只補足其他時段，不得覆蓋作者設定。只使用輸入角色的設定與作者提供的行程方向，不可替角色創造與背景衝突的現代身分。",
    "若輸入包含 character_ai_profile，必須讀取先前角色資料整理 AI 已保存的身份背景、核心個性、內在動機、情緒反應、關係互動、行為主動性、知識界線、說話風格與角色一致性規則，作為推演日常活動、工作內容及社交場景的主要參考；author_character_profile 是作者原始設定，若與整理結果有差異，以作者明示內容為準。unknowns 與 source_conflicts 代表尚未確認，不可自行補造，也不可將 AI 推論寫成作者明示。公開 activity 不得揭露私密資訊。",
    "若輸入包含 character_life_context，必須將其視為先前由角色原始設定整理並保存的生活環境參考；優先讀取有來源支持的工作環境、住所、日常作息、興趣、社交圈、常去場所與生活限制。status=not_provided 或空 items 代表未知，不可自行補造；ai_inference 必須視為推論而非作者明示。若此欄位不存在或為 null，才退回原始角色卡與作者私密設定推演。不得為取得生活環境而在行程生成階段再次呼叫分析 AI。",
    "若輸入包含 character_life_context，必須將其視為先前由角色原始設定整理並保存的生活環境參考；優先讀取有來源支持的工作環境、住所、日常作息、興趣、社交圈、常去場所與生活限制。status=not_provided 或空 items 代表未知，不可自行補造；ai_inference 必須視為推論而非作者明示。若此欄位不存在或為 null，才退回原始角色卡與作者私密設定推演。不得為取得生活環境而在行程生成階段再次呼叫分析 AI。",
    "不得向模型提供任何地圖地點建議、場景名稱範例或地點白名單。必須只依角色職業、經濟能力、個性、興趣、作息、生活圈與背景，自行推演合理地點；不可為了配合地圖而改寫角色生活或硬塞地點。每個選項只寫一個明確地點，地點名稱最多 20 個字（空格不計），允許括號等辨識名稱，例如「歸途（酒吧）」，不得用「或」、斜線、頓號等串接多個地點。工作活動必須使用實際工作場所，居家活動才使用住所；例如顧言在代辦所辦公，地點應為「代辦所」，不可因住所是公寓就把工作地點寫成公寓。不得輸出 location_key、場景 ID、座標或任何系統場景分類。地點是否能對應地圖由系統自行判斷，無法媒合時仍保留原地點與行程。",
    "airport 是特殊地點：只有角色本身職業／設定與航空機場有明確關聯，或作者設定有具體搭機、接送、轉機、出入境行程時才能使用。不得把機場當一般休閒、辦公或隨機偶遇地點；沒有明確理由時不得使用機場，應依角色背景自行推導合理地點。",
    "行程以角色自身日常活動為準，AI 不得判斷玩家是否能相遇、地點是否適合公開相遇或地圖是否顯示。weekday 與 holiday 各自必須完整輸出 24 個逐小時時段，從 00:00–01:00 到 23:00–00:00，不能有空檔、重疊或合併時段。必須按小時逐一輸出，完整包含 00、01、02、03、04、05、06、07、08、09、10、11、12、13、14、15、16、17、18、19、20、21、22、23 共 24 格；不可因角色睡眠、休息、待命、沒有工作或某時段不重要而省略。完成草稿後，輸出前先自我檢查兩種 day_type 的時段清單：每種均為 24 格、每格恰好 1 小時、起訖連續且從 00:00 開始至隔日 00:00 結束，沒有缺漏、重複、重疊或跨時段合併；若檢查失敗，必須先修正完整 JSON 再輸出。每個時段必須提供 2–3 個選項，不得少於 2 個或多於 3 個；即使固定工作或睡眠，也必須提出至少兩種符合角色背景的合理活動或情境，不得用單一選項 100% 規避機率，也不可為湊數虛構不合理活動。每個選項只輸出 weight、location、activity、is_outdoor、rain_fallback_location、rain_fallback_activity 六個欄位。activity 與 rain_fallback_activity 各 8–30 個中文字，直接描述角色正在做的事；不需要 scene_description、招呼語或長篇敘事。若角色正在睡覺，activity 必須明確寫出熟睡、睡著、睡覺中等可辨識狀態。每個時段所有選項 weight 必須是 1–99 的整數且總和必須恰好 100；weight 是該時段整組地點與行為實際發生的相對機率，依角色日常發生可能性設定，不可全部固定相同權重。不同時段獨立抽取：各時段依權重獨立抽選，同一時段的地點與行為必須整組一起切換；相鄰時段仍須符合交通與作息邏輯。即使地點無法媒合地圖，也必須保留自然地點與行為描述，是否能相遇及是否顯示由系統判斷。",
    "weekday 與 holiday 是日曆情境，不等於角色的上班日與休假日。依台灣政府正式辦公日曆及補班日決定 day_type；AI 必須根據角色職業與作者設定，分別推演平日和假日的生活節奏，不可假設所有人週末休息。系統每天依角色、日期與時段獨立執行加權抽取，同一天同一時段結果固定，重新整理地圖不會重新抽籤；不同日期會使用不同抽取種子。機率只在同一角色、同一日期類型、同一個小時的 options 內比較，絕不可跨時段或跨平日／假日共用權重。",
    "行程只分 weekday 與 holiday；節日、國定假日與補班日由系統依台灣日曆映射到相應日期類型，不要另外生成 special_events，也不可自行推算角色生日。",
    "戶外時段必須提供合理的雨天替代地點與替代行為，雨天行為也限制 8–30 個中文字；優先選擇室內場所。室內時段通常可將 rain_fallback_location 與 rain_fallback_activity 設為 null，但若角色在雨天改變活動或選擇不出門，AI 也可提供合理備案。雨天備案不必強制對應現有地圖場景；無法媒合時保留自然地點描述並由系統留空場景 key。是否戶外及地點對應何種系統場景，由系統判斷。",
    "is_outdoor 必須依活動實際發生的空間判斷，不能只看地點名稱；地點描述與活動空間是兩個獨立欄位。客戶家維修、搬家、清潔等工作發生在室內；餐廳／小吃店用餐、超商內購物或結帳都屬室內。POYOZZ 特別規則：角色在自己公寓陽台抽菸仍判定為室內，地點使用住所。計程車內送客屬車內活動，is_outdoor=false，地點可寫「街頭」，不可錯掛在餐廳，也不可建立或要求計程車場景；角色下車後在街頭道別或步行才判定為戶外。不得因地點對應到街道或商圈就把車內／店內活動標為戶外。",

    "作者行程說明只供內部規劃；activity 必須使用公開可見、簡短自然的描述，不得逐字複製整段說明或揭露私密情節。",


    "輸出必須是嚴格 JSON object，唯一根欄位 characters。每個角色欄位為 character_id, placement, variants。所有送入的角色一律使用 placement=modern_map，variants 只包含 weekday 與 holiday，各自必須恰好 24 個逐小時時段；每個時段物件欄位為 start_time, end_time, options。options 為 2–3 個選項，每個選項且只能有 weight, location, activity, is_outdoor, rain_fallback_location, rain_fallback_activity 六個欄位。同一時段 options 的 weight 總和必須為 100。不輸出 no_matching_location、special_events、scenes、招呼語、scene_description、關係招呼池、場景 ID、座標、額外欄位或 Markdown。",
  ].join("\n");
  return {
    messages: [
      { role: "system", content: system },
      { role: "user", content: JSON.stringify({
        characters: promptSources,
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
      Object.keys(item).some((key) => !["character_id", "placement", "variants", "special_events"].includes(key)) ||
      !isUuid(item.character_id)) {
      errors.push("character_item_invalid");
      continue;
    }
    const rawSpecialEvents = item.special_events === undefined ? [] : item.special_events;
    if (!Array.isArray(rawSpecialEvents) || rawSpecialEvents.length !== 0) {
      errors.push("special_events_must_be_empty");
      continue;
    }
    const specialEvents: SpecialEventSchedule[] = [];
    const id = item.character_id;
    const source = sourceById.get(id);
    if (!source || source.visibility !== "public" || source.deleted_at != null || seen.has(id)) {
      errors.push("character_identity_duplicate_or_unknown");
      continue;
    }
    seen.add(id);
    const modernMapCompatible = isEncounterModernMapCompatible(source);
    if (item.placement === "no_matching_location" && !modernMapCompatible) {
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
    // For modern-compatible roles, placement is a map-eligibility decision only.
    // A model-side no_matching_location must never erase a valid natural schedule:
    // scene matching is performed independently after parsing.
    if (!modernMapCompatible || !["modern_map", "no_matching_location"].includes(String(item.placement))) {
      errors.push(id + "_modern_map_placement_not_allowed");
      continue;
    }
    if (!hasExactKeys(item.variants, ["weekday", "holiday"]) ||
      !Array.isArray(item.variants.weekday) || !Array.isArray(item.variants.holiday)) {
      errors.push(id + "_day_type_variants_invalid");
      continue;
    }
    const profile = isRecord(source.personality_profile) ? source.personality_profile : {};
    const residenceContext = [
      ...collectResidentialProfileContext(source.derived_life_context),
      ...collectResidentialProfileContext(source.derived_character_profile),
      ...collectResidentialProfileContext(profile),
      ...[text(source.intro), text(source.schedule_description), text(source.private_info)]
        .filter((value) => /(?:居住|住在|住於|住所|住處|自宅|自己的家|家中)/.test(value) && hasExplicitLuxuryResidenceContext(value)),
    ].join(" ");
    const weekday = validateHourlySchedule(item.variants.weekday, errors, id + "_weekday", residenceContext);
    const holiday = validateHourlySchedule(item.variants.holiday, errors, id + "_holiday", residenceContext);
    const scheduleSlots = [
      ...(weekday ?? []).flatMap((block) => block.options),
      ...(holiday ?? []).flatMap((block) => block.options),
      ...specialEvents.flatMap((event) => event.slots),
    ];
    if (scheduleSlots.some((slot) =>
      (slot.location_key === "airport" || slot.rain_fallback_location_key === "airport") &&
      !isAirportUseReasonable(source, slot.activity))) {
      errors.push(id + "_airport_location_without_character_context");
    }
    if (weekday && holiday) {
      characters.push({
        character_id: id, placement: "modern_map", variants: { weekday, holiday },
        special_events: specialEvents,
      });
    }
  }

  // System-side exact-name matching for custom registered scenes. The catalog
  // is never included in the AI prompt; unmatched descriptions stay intact.
  const catalogByDisplayName = new Map(
    sceneCatalog
      .map((scene) => [text(scene.display_name).toLocaleLowerCase(), normalizeEncounterSceneKey(scene.location_key)] as const)
      .filter((entry): entry is readonly [string, string] => Boolean(entry[0] && entry[1])),
  );
  for (const character of characters) {
    const allSlots = [
      ...character.variants.weekday.flatMap((block) => block.options),
      ...character.variants.holiday.flatMap((block) => block.options),
      ...character.special_events.flatMap((event) => event.slots),
    ];
    for (const slot of allSlots) {
      if (slot.location_key) continue;
      slot.location_key = catalogByDisplayName.get(slot.location_description.toLocaleLowerCase()) ?? null;
    }
  }

  const scenes: GeneratedSceneMetadata[] = [];
  const rawScenes = parsed.scenes === undefined ? [] : parsed.scenes;
  if (!Array.isArray(rawScenes) || rawScenes.length !== 0) {
    errors.push("scene_metadata_must_be_empty");
  }

  if (seen.size !== sources.length) errors.push("character_coverage_incomplete");
  return {
    ok: errors.length === 0,
    characters: errors.length === 0 ? characters : [],
    scenes: errors.length === 0 ? scenes : [],
    errors: [...new Set(errors)],
  };
}
