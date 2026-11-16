import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const start = html.indexOf('const characterVideoSignedUrlManager');
const end = html.indexOf('function normalizePersonalityProfile', start);
if (start < 0 || end < 0) throw new Error('Character video loader block not found.');
const source = html.slice(start, end);

if (!source.includes("CHARACTER_VIDEO_VISIBILITY_DELAY_MS = 500")) {
  throw new Error('Video must wait 500ms after becoming meaningfully visible before signing or loading.');
}
if (!source.includes('scheduleCharacterVideoLoad(target)')) {
  throw new Error('Visible video loading must pass through the dwell-time gate.');
}
if (!source.includes('clearCharacterVideoVisibilityTimer(target)')) {
  throw new Error('Leaving the visibility threshold must cancel a pending video load.');
}
if (!source.includes("video.dataset.videoVisibilityEligible!=='true'")) {
  throw new Error('A delayed video load must re-check current visibility eligibility.');
}
if (!source.includes('isCharacterVideoMeaningfullyVisible(video)')) {
  throw new Error('Delayed loads and the no-IntersectionObserver fallback must re-check the 35% visible-area threshold.');
}
if (!source.includes('(width*height)/totalArea>=0.35')) {
  throw new Error('The fallback visibility calculation must preserve the 35% threshold.');
}
if (!source.includes("video.dataset.videoHydrated==='loading'")) {
  throw new Error('The dwell scheduler must not enqueue another load while a video is already signing or hydrating.');
}
if (!source.includes("video.dataset.videoVisibilityEligible!=='true'\n        ||!isCharacterVideoMeaningfullyVisible(video)")) {
  throw new Error('An in-flight signed URL must be discarded if the video leaves the 35% visibility threshold before attaching src.');
}
if (!source.includes("threshold:[0,0.15,0.35]")) {
  throw new Error('Video observer must use graduated visibility thresholds.');
}
if (!source.includes('entry.intersectionRatio>=0.35')) {
  throw new Error('Video must not hydrate until at least 35% is visible.');
}
if (!source.includes('entry.intersectionRatio<0.15')) {
  throw new Error('Loaded video must pause when less than 15% is visible.');
}
if (!source.includes("target.dataset.videoHydrated==='true'")) {
  throw new Error('Existing hydrated video reuse path must remain.');
}
if (!source.includes('pauseCharacterVideo(target)')) {
  throw new Error('Off-screen video pause path must remain.');
}
if (!source.includes('video.src=signedUrl')) {
  throw new Error('Signed URL media source attachment must remain.');
}
console.log('Character video visibility-threshold checks passed.');
