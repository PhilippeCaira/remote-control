# Branding assets

Drop-in assets consumed by `client/scripts/apply-branding.sh` at build time.

Every path below is optional: the script skips any asset that is not yet
present so that the CI pipeline can be exercised before the full set exists.
However, a **release** build must include the full set — the CI release
workflow treats missing assets as a failure.

## Required assets

### `assets/` — icons

| File                     | Size/format             | Consumed by                                   |
|--------------------------|-------------------------|-----------------------------------------------|
| `icon.ico`               | Windows `.ico`, 256x256 | Windows EXE/MSI                               |
| `icon.icns`              | macOS `.icns` (multi)   | macOS app bundle                              |
| `icon-128.png`           | 128x128 PNG             | Linux / tray fallback                         |
| `icon-32.png`            | 32x32 PNG               | Linux small icon                              |
| `icon-mac.png`           | 512x512 PNG             | macOS status-bar                              |
| `tray-icon.ico`          | 16/32/64 ICO            | Windows system tray                           |
| `logo.png`               | 512x512 PNG             | Flutter in-app logo (about screen, splash)    |

### `assets/android/` — Android launcher

Provide both `ic_launcher_*` and `ic_launcher_round_*` for each density:

| Density   | Pixel size |
|-----------|------------|
| mdpi      | 48x48      |
| hdpi      | 72x72      |
| xhdpi     | 96x96      |
| xxhdpi    | 144x144    |
| xxxhdpi   | 192x192    |

Example: `assets/android/ic_launcher_xxxhdpi.png`.

### `splash/` — Flutter splash screens

| File                | Size            |
|---------------------|-----------------|
| `splash.png`        | 1024x1024 PNG   |
| `splash-dark.png`   | 1024x1024 PNG   |

Transparent background recommended; they are composed onto the theme color
by Flutter at runtime.

## Recommended source artifact

Keep a **single 1024x1024 SVG or PNG** in `assets/logo-source.svg` and
regenerate every raster from it. The convenience script below derives the
full set; install ImageMagick + `png2icns` first.

```bash
# From repo root, one-shot regeneration (ImageMagick 7).
SRC="client/branding/assets/logo-source.svg"
OUT="client/branding/assets"

# Windows
magick "$SRC" -background none -resize 256x256 "$OUT/icon.ico"
magick "$SRC" -background none -resize 64x64   "$OUT/tray-icon.ico"

# macOS (requires libicns' png2icns)
magick "$SRC" -background none -resize 1024x1024 /tmp/icon-1024.png
png2icns "$OUT/icon.icns" /tmp/icon-1024.png
magick "$SRC" -background none -resize 512x512 "$OUT/icon-mac.png"

# Generic PNG
magick "$SRC" -background none -resize 128x128 "$OUT/icon-128.png"
magick "$SRC" -background none -resize 32x32  "$OUT/icon-32.png"
magick "$SRC" -background none -resize 512x512 "$OUT/logo.png"

# Android launcher — mdpi 48, hdpi 72, xhdpi 96, xxhdpi 144, xxxhdpi 192
for sz_density in 48:mdpi 72:hdpi 96:xhdpi 144:xxhdpi 192:xxxhdpi; do
    sz="${sz_density%%:*}" d="${sz_density##*:}"
    magick "$SRC" -background none -resize "${sz}x${sz}"        "$OUT/android/ic_launcher_${d}.png"
    magick "$SRC" -background none -resize "${sz}x${sz}" \
        \( +clone -threshold -1 -negate -fill white -draw "circle $((sz/2)),$((sz/2)) $((sz/2)),0" \) \
        -alpha off -compose CopyOpacity -composite \
        "$OUT/android/ic_launcher_round_${d}.png"
done

# Splash
magick "$SRC" -background none        -resize 1024x1024 "$OUT/../splash/splash.png"
magick "$SRC" -background "#101216"   -resize 1024x1024 "$OUT/../splash/splash-dark.png"
```

Store `logo-source.svg` alongside the rasters — it's the canonical source
and small enough to commit.

## Strings and bundle identifiers

Renaming the binary itself (product name, Windows/macOS bundle IDs,
Android package) is a **patch operation** — it lives in `client/patches/`,
not here. The rationale is that these strings are scattered across
`pubspec.yaml`, `AndroidManifest.xml`, `AppInfo.xcconfig`, and
`Cargo.toml`; a set of focused patches is easier to rebase across upstream
updates than a code generator.

See `docs/02-client-build.md` (created in the next milestone) for the list
of patches and how to regenerate them after an upstream `git subtree pull`.
