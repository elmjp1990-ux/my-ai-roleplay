const DATE_PATTERN = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/;

function calendarRows(payload) {
  if (Array.isArray(payload)) return payload;
  if (Array.isArray(payload?.data)) return payload.data;
  if (Array.isArray(payload?.records)) return payload.records;
  if (Array.isArray(payload?.result)) return payload.result;
  return [];
}

function isHolidayValue(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (value === true || ["true", "1", "y", "yes", "是", "放假"].includes(normalized)) return true;
  if (value === false || ["false", "0", "n", "no", "否", "上班"].includes(normalized)) return false;
  return null;
}

export function parseTaiwanCalendarRows(payload, source = "data.gov.tw:123662") {
  const output = [];
  for (const item of calendarRows(payload)) {
    const row = item && typeof item === "object" ? item : {};
    const rawDate = String(row.date ?? row.Date ?? row.日期 ?? "").trim();
    const match = DATE_PATTERN.exec(rawDate);
    if (!match) continue;
    const year = Number(match[1]), month = Number(match[2]), day = Number(match[3]);
    const date = new Date(Date.UTC(year, month - 1, day));
    if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) continue;
    const holiday = isHolidayValue(row.isholiday ?? row.isHoliday ?? row.IsHoliday ?? row.是否放假);
    if (holiday === null) continue;
    const rawName = String(row.name ?? "").trim();
    const rawDescription = String(row.description ?? "").trim();
    const rawCategory = String(row.holidaycategory ?? "").trim();
    const genericWeekendLabel = /^(?:週末假期|周末假期|星期六|星期日|週六|週日|放假|放假日|休假日|假日|例假日)$/i;
    const holidayName = [rawName, rawDescription]
      .find((value) => value && !genericWeekendLabel.test(value)) ||
      (rawCategory && !genericWeekendLabel.test(rawCategory) ? rawCategory : "");
    output.push({
      calendar_date: year + "-" + String(month).padStart(2, "0") + "-" + String(day).padStart(2, "0"),
      day_type: holiday ? "holiday" : "workday",
      // holidaycategory is only a fallback when it is not a generic weekend label.
      holiday_name: holidayName.slice(0, 120) || null,
      source,
    });
  }
  return output;
}
