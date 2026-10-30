const TAIPEI_TIME_ZONE = "Asia/Taipei";

function getTaipeiParts(date) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: TAIPEI_TIME_ZONE, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(date);
  const value = (type) => parts.find((part) => part.type === type)?.value || "";
  return { date: `${value("year")}-${value("month")}-${value("day")}`, minute: Number(value("hour")) * 60 + Number(value("minute")) };
}

function dateAtOffset(date, offset) {
  const value = new Date(`${date}T12:00:00+08:00`);
  value.setUTCDate(value.getUTCDate() + offset);
  return value.toISOString().slice(0, 10);
}

function weekdayFor(date) { return new Date(`${date}T12:00:00+08:00`).getUTCDay(); }

function parseScheduleMinute(value) {
  if (typeof value !== "string") return Number.NaN;
  const match = /^(\d{2}):(\d{2})(?::\d{2})?$/.exec(value);
  if (!match) return Number.NaN;
  const hour = Number(match[1]); const minute = Number(match[2]);
  if (hour > 23 || minute > 59) return Number.NaN;
  return hour * 60 + minute;
}

function formatScheduleTime(value) {
  return `${String(Math.floor(value / 60)).padStart(2, "0")}:${String(value % 60).padStart(2, "0")}:00`;
}

// Schedule weekday/day_type apply to the local date on which the interval starts.
export function resolveEncounterSchedule(rows, locationKey, now = new Date()) {
  if (!Array.isArray(rows) || typeof locationKey !== "string" || !(now instanceof Date) || Number.isNaN(now.getTime())) return null;
  const local = getTaipeiParts(now);
  if (!local.date || !Number.isInteger(local.minute) || local.minute < 0 || local.minute >= 1440) return null;
  const matches = [];
  for (const row of rows) {
    if (!row || row.is_active !== true || row.location_key !== locationKey) continue;
    const start = parseScheduleMinute(row.start_time);
    const end = parseScheduleMinute(row.end_time);
    if (!Number.isInteger(start) || !Number.isInteger(end) || start === end) continue;
    const overnight = end < start;
    for (const dayOffset of [-1, 0]) {
      if (dayOffset === -1 && !overnight) continue;
      const scheduleDate = dateAtOffset(local.date, dayOffset);
      const scheduleWeekday = weekdayFor(scheduleDate);
      if (row.weekday !== null && row.weekday !== undefined && Number(row.weekday) !== scheduleWeekday) continue;
      const weekend = scheduleWeekday === 0 || scheduleWeekday === 6;
      const dayType = row.day_type ?? "any";
      if (dayType !== "any" && dayType !== "weekday" && dayType !== "weekend") continue;
      if (dayType === "weekday" && weekend) continue;
      if (dayType === "weekend" && !weekend) continue;
      const inWindow = dayOffset === -1 ? local.minute < end : overnight ? local.minute >= start : local.minute >= start && local.minute < end;
      if (!inWindow) continue;
      matches.push({ row, startDate: scheduleDate, endDate: overnight ? dateAtOffset(scheduleDate, 1) : scheduleDate, start, end, weekdaySpecific: row.weekday !== null && row.weekday !== undefined });
    }
  }
  matches.sort((a, b) => (Number(b.row.priority) || 0) - (Number(a.row.priority) || 0) || Number(b.weekdaySpecific) - Number(a.weekdaySpecific) || String(a.row.id ?? "").localeCompare(String(b.row.id ?? "")));
  const selected = matches[0];
  if (!selected) return null;
  const scheduledStartAt = new Date(`${selected.startDate}T${formatScheduleTime(selected.start)}+08:00`).toISOString();
  const scheduledEndAt = new Date(`${selected.endDate}T${formatScheduleTime(selected.end)}+08:00`).toISOString();
  return { scheduledStartAt, scheduledEndAt, scheduleSnapshot: {
    schedule_id: selected.row.id ?? null, weekday: selected.row.weekday ?? null, day_type: selected.row.day_type ?? "any",
    start_time: selected.row.start_time, end_time: selected.row.end_time, location_key: locationKey,
    activity: selected.row.activity ?? "", priority: selected.row.priority ?? 0, timezone: TAIPEI_TIME_ZONE, verified_at: now.toISOString(),
  } };
}