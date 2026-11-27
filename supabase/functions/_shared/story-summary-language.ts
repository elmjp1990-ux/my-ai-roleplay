export function detectPlayerSummaryLanguage(userTexts: string[]): string {
  const combined = userTexts.join("\n");
  const traditionalMarkers = "這個為與說話時會後還開關點線體現讓過從進發愛歡觀見實務兩請對應學處經無們來個專業";
  const simplifiedMarkers = "这个为与说话时会后还开关点线体现让过从进发爱欢观见实务两请对应学处经无们来个专业";
  const countChars = (text: string, markers: string) => Array.from(text).filter((char) => markers.includes(char)).length;
  const traditional = countChars(combined, traditionalMarkers);
  const simplified = countChars(combined, simplifiedMarkers);
  const latin = (combined.match(/[A-Za-z]/g) || []).length;
  const han = (combined.match(/[\u3400-\u9fff]/g) || []).length;
  const kana = (combined.match(/[\u3040-\u30ff]/g) || []).length;
  const hangul = (combined.match(/[\uac00-\ud7af]/g) || []).length;
  if (traditional > simplified && traditional >= 2) return "繁體中文（使用繁體字，不得轉為簡體中文）";
  if (simplified > traditional && simplified >= 2) return "簡體中文（使用簡體字）";
  if (kana > 0) return "日文";
  if (hangul > 0) return "韓文";
  if (latin > han) return "英文";
  const latest = userTexts.at(-1) || combined;
  const latestTraditional = countChars(latest, traditionalMarkers);
  const latestSimplified = countChars(latest, simplifiedMarkers);
  if (latestTraditional > latestSimplified) return "繁體中文（使用繁體字，不得轉為簡體中文）";
  if (latestSimplified > latestTraditional) return "簡體中文（使用簡體字）";
  if (/[\u3400-\u9fff]/.test(latest)) return "沿用玩家最新輸入中的中文書寫方式，若為繁體則用繁體，若為簡體則用簡體";
  return "沿用玩家主要使用的語言";
}
