import fs from "node:fs/promises";
import sharp from "sharp";

const assets = [
  {
    input: "LOGO_WEBLOGO.png",
    output: "LOGO_WEBLOGO.webp",
    width: 600,
    height: 180,
    quality: 82,
    label: "brand wordmark"
  },
  {
    input: "LOGO_WEBICON.png",
    output: "LOGO_WEBICON.webp",
    width: 256,
    height: 256,
    quality: 82,
    label: "brand icon"
  },
  {
    input: "Prosperous_daytime_cityscape_pai…_2K_20261027142908 (1).webp",
    output: "encounter-default-scene.webp",
    width: 1440,
    height: 1440,
    quality: 76,
    label: "default encounter scene"
  }
];

for (const asset of assets) {
  const before = await fs.stat(asset.input);
  const metadata = await sharp(asset.input).metadata();
  const result = await sharp(asset.input)
    .rotate()
    .resize({
      width: asset.width,
      height: asset.height,
      fit: "inside",
      withoutEnlargement: true
    })
    .webp({
      quality: asset.quality,
      alphaQuality: 90,
      effort: 6,
      smartSubsample: true
    })
    .toFile(asset.output);

  const reduction = Math.max(0, 1 - result.size / before.size);
  console.log(
    `${asset.label}: ${metadata.width}x${metadata.height}, ${before.size} -> ${result.size} bytes (${(reduction * 100).toFixed(1)}% smaller)`
  );
}
