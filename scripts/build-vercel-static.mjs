import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const outputDir = path.join(root, 'dist');

// Explicit deployment allowlist. Keep repository tooling, SQL, drafts, and unused
// source assets in GitHub, but do not publish them as Vercel static files.
const runtimeFiles = [
  'index.html',
  'memory-capture.js',
  'LOGO_WEBICON.webp',
  'LOGO_WEBLOGO.webp',
  'encounter-default-scene.webp',
];

fs.rmSync(outputDir, { recursive: true, force: true });
fs.mkdirSync(outputDir, { recursive: true });

for (const relativePath of runtimeFiles) {
  const source = path.join(root, relativePath);
  if (!fs.existsSync(source)) {
    throw new Error('Required Vercel runtime file is missing: ' + relativePath);
  }
  const sourceStat = fs.lstatSync(source);
  if (!sourceStat.isFile() || sourceStat.isSymbolicLink()) {
    throw new Error('Vercel runtime source must be a regular, non-symlink file: ' + relativePath);
  }
  fs.copyFileSync(source, path.join(outputDir, relativePath));
}

console.log('Prepared Vercel static output with ' + runtimeFiles.length + ' runtime files.');
