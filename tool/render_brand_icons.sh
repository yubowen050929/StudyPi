#!/usr/bin/env bash
# Render the StudyPi brand SVGs in assets/brand to the PNGs used by
# flutter_launcher_icons, flutter_native_splash and the app itself.
# Needs a Chromium/Chrome binary (CHROME=...) and ImageMagick.
# Then run: dart run flutter_launcher_icons && dart run flutter_native_splash:create
set -euo pipefail
cd "$(dirname "$0")/../assets/brand"
: "${CHROME:?set CHROME to a Chromium or Chrome binary}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

render() { # <name> <size>
  cp "$1.svg" "$tmp/"
  printf '<html><body style="margin:0"><img src="%s.svg" style="width:%spx;height:%spx;display:block"></body></html>' \
    "$1" "$2" "$2" > "$tmp/page.html"
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size="$2,$2" \
    --screenshot="$PWD/$1.png" "file://$tmp/page.html" > /dev/null 2>&1
}

for name in studypi_icon studypi_icon_rounded studypi_icon_dark_transparent \
  studypi_adaptive_background studypi_adaptive_foreground studypi_adaptive_monochrome; do
  render "$name" 1024
done
render studypi_splash 768
render studypi_splash_android12 1152
render studypi_tray_template 180

cp studypi_icon.png ../app_icon.png
cp studypi_tray_template.png ../icon_mac.png
magick studypi_icon_rounded.png -define icon:auto-resize=256,128,64,48,32,24,16 ../app_icon.ico
rm -f studypi_tray_template.png
