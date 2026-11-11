import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const start = html.indexOf('const characterVideoSignedUrlCache');
const end = html.indexOf('function normalizePersonalityProfile', start);
if (start < 0 || end < 0) throw new Error('Character video loader block not found.');
const source = html.slice(start, end);

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
