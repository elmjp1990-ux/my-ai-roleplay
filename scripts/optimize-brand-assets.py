from pathlib import Path
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]


def optimize(source_name: str, output_name: str, max_size: tuple[int, int], required: bool) -> bool:
    source = ROOT / source_name
    output = ROOT / output_name
    if not source.exists():
        if required:
            raise FileNotFoundError(f"Required brand source is missing: {source_name}")
        print(f"Optional brand source missing; keeping PNG reference: {source_name}")
        return False
    try:
        with Image.open(source) as original:
            image = ImageOps.exif_transpose(original).convert("RGBA")
            image.thumbnail(max_size, Image.Resampling.LANCZOS)
            image.save(output, "WEBP", quality=84, method=6)
    except Exception as error:
        if required:
            raise
        print(f"Optional icon could not be optimized ({error}); keeping PNG reference.")
        return False
    before, after = source.stat().st_size, output.stat().st_size
    print(f"{source_name}: {before:,} bytes -> {output_name}: {after:,} bytes")
    if after >= before:
        print(f"Warning: optimized asset is not smaller than source: {output_name}")
    return True


def main() -> None:
    optimize("LOGO_WEBLOGO.png", "LOGO_WEBLOGO.webp", (720, 240), required=True)
    icon_ok = optimize("LOGO_WEBICON.png", "LOGO_WEBICON.webp", (256, 256), required=False)
    if not icon_ok:
        index_path = ROOT / "index.html"
        html = index_path.read_text(encoding="utf-8")
        html = html.replace("LOGO_WEBICON.webp", "LOGO_WEBICON.png")
        html = html.replace('type="image/webp" href="./LOGO_WEBICON.png"', 'type="image/png" href="./LOGO_WEBICON.png"')
        index_path.write_text(html, encoding="utf-8")


if __name__ == "__main__":
    main()
