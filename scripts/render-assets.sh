#!/usr/bin/env bash
#
# Render the original assets in statics/ into the app asset catalog
# (TransportCat/Resources/Assets.xcassets) as @3x PNG image sets (spec S7).
#
#   - train-<line>:    copy of statics/map-trains/<line>@3x.png (180x150 px)
#   - badge-<line>:    statics/lines/<line>.svg at 192x120 px (64x40 pt)
#   - station-<line>:  statics/markers/station.svg re-tinted to the line color
#   - terminal-<line>: statics/markers/station-terminal.svg, same re-tint
#   - tab-*/icon-*:    statics/icons/*.svg with currentColor -> black, template
#     (icon-escalator, icon-elevator and icon-entrance are the incident kind
#     icons drawn in the station rows of the diagram, spec S7)
#
# <line> is MetroLine.displayName lowercased (l1 ... l9n, l10s, l11, fm) and the
# hex colors are read from TransportCat/Core/Models/MetroLine.swift, so the
# catalog can never drift from the colors the app draws with.
#
# The PNG sources are committed; re-run this script after changing anything in
# statics/ or after a line color changes. Requires rsvg-convert.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_DIR="$REPO_ROOT/statics"
MODEL_FILE="$REPO_ROOT/TransportCat/Core/Models/MetroLine.swift"
CATALOG_DIR="$REPO_ROOT/TransportCat/Resources/Assets.xcassets"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "ERROR: rsvg-convert is required (pacman -S librsvg)" >&2
    exit 1
fi
for required in "$STATIC_DIR" "$MODEL_FILE" "$CATALOG_DIR"; do
    if [[ ! -e "$required" ]]; then
        echo "ERROR: missing $required" >&2
        exit 1
    fi
done

# Markers ship with the L5 blue as default fill; that is the token to replace.
DEFAULT_MARKER_FILL="#005A97"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --------------------------------------------------------------------------
# Line keys and colors, parsed from the model (single source of truth).
# Yields one "key hex" pair per line, in MetroLine.allLines order.
# --------------------------------------------------------------------------
line_specs() {
    sed -nE 's/.*displayName: "([^"]+)", colorHex: "([0-9A-Fa-f]{6})".*/\1 \2/p' "$MODEL_FILE" \
        | tr '[:upper:]' '[:lower:]'
}

# --------------------------------------------------------------------------
# Asset catalog helpers
# --------------------------------------------------------------------------

# write_contents <imageset-dir> <png-file-name> [template]
write_contents() {
    local dir="$1" filename="$2" rendering="${3:-}"
    local properties=""
    if [[ "$rendering" == "template" ]]; then
        properties=',
        "properties": {
          "template-rendering-intent": "template"
        }'
    fi
    cat >"$dir/Contents.json" <<JSON
{
  "images": [
    {
      "idiom": "universal",
      "filename": "$filename",
      "scale": "3x"${properties}
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
JSON
}

# assert_rgba <png> — every map asset is drawn over the map, so it must keep
# its transparency instead of arriving with an opaque background box.
assert_rgba() {
    local png="$1" info
    info="$(file "$png")"
    case "$info" in
        *RGBA* | *"with alpha"*) ;;
        *)
            echo "ERROR: $png has no alpha channel: $info" >&2
            exit 1
            ;;
    esac
}

# emit_imageset <name> <source-png> [template]
emit_imageset() {
    local name="$1" source="$2" rendering="${3:-}" dir png
    dir="$CATALOG_DIR/$name.imageset"
    mkdir -p "$dir"
    # Keep the catalog clean: an old render under another file name would stay
    # in the bundle and Xcode warns about duplicated imageset entries.
    find "$dir" -maxdepth 1 -name '*.png' -delete
    png="$dir/$name@3x.png"
    cp "$source" "$png"
    write_contents "$dir" "$name@3x.png" "$rendering"
    assert_rgba "$png"
    generated+=("$name")
}

# render_png <source-svg> <out-png> <width> <height>
render_png() {
    local svg="$1" out="$2" width="$3" height="$4"
    rsvg-convert -w "$width" -h "$height" "$svg" -o "$out"
}

# tint_svg <source-svg> <out-svg> <from> <to> — case-insensitive color swap on
# a temporary copy; the sources in statics/ are never modified.
tint_svg() {
    local svg="$1" out="$2" from="$3" to="$4"
    sed "s/${from}/${to}/Ig" "$svg" >"$out"
    if ! grep -qF -- "$to" "$out"; then
        echo "ERROR: $from not found in $svg, nothing was re-tinted" >&2
        exit 1
    fi
}

generated=()

# A silent parse failure here would render nothing and still exit 0, so check it
# once up front instead of trusting the loops below.
if [[ -z "$(line_specs)" ]]; then
    echo "ERROR: no displayName/colorHex pairs parsed from $MODEL_FILE" >&2
    exit 1
fi

# --------------------------------------------------------------------------
# 1. Directional train markers (pre-exported PNG, faces east)
# --------------------------------------------------------------------------
while read -r key hex; do
    source="$STATIC_DIR/map-trains/$key@3x.png"
    if [[ ! -f "$source" ]]; then
        echo "ERROR: missing $source" >&2
        exit 1
    fi
    emit_imageset "train-$key" "$source"
done < <(line_specs)

# --------------------------------------------------------------------------
# 2. Line badges, 64x40 pt at 3x
# --------------------------------------------------------------------------
while read -r key hex; do
    render_png "$STATIC_DIR/lines/$key.svg" "$TMP_DIR/$key-badge.png" 192 120
    emit_imageset "badge-$key" "$TMP_DIR/$key-badge.png"
done < <(line_specs)

# --------------------------------------------------------------------------
# 3. Station and terminal markers, 24 pt at 3x, re-tinted to the line color
# --------------------------------------------------------------------------
while read -r key hex; do
    tint_svg "$STATIC_DIR/markers/station.svg" "$TMP_DIR/$key-station.svg" \
        "$DEFAULT_MARKER_FILL" "#$hex"
    render_png "$TMP_DIR/$key-station.svg" "$TMP_DIR/$key-station.png" 72 72
    emit_imageset "station-$key" "$TMP_DIR/$key-station.png"

    tint_svg "$STATIC_DIR/markers/station-terminal.svg" "$TMP_DIR/$key-terminal.svg" \
        "$DEFAULT_MARKER_FILL" "#$hex"
    render_png "$TMP_DIR/$key-terminal.svg" "$TMP_DIR/$key-terminal.png" 72 72
    emit_imageset "terminal-$key" "$TMP_DIR/$key-terminal.png"
done < <(line_specs)

# --------------------------------------------------------------------------
# 4. Tab and status icons, 24 pt at 3x, template rendering.
# Icons use currentColor, which resolves to black outside a CSS context.
# --------------------------------------------------------------------------
for icon_spec in \
    "tab-map:map" \
    "tab-network:network" \
    "tab-alert:service-alert" \
    "icon-accessible:accessible" \
    "icon-alert:service-alert" \
    "icon-escalator:escalator" \
    "icon-elevator:elevator" \
    "icon-entrance:station-entrance"; do
    name="${icon_spec%%:*}"
    source_svg="$STATIC_DIR/icons/${icon_spec#*:}.svg"
    tinted="$TMP_DIR/$name.svg"
    tint_svg "$source_svg" "$tinted" "currentColor" "#000000"
    render_png "$tinted" "$TMP_DIR/$name.png" 72 72
    emit_imageset "$name" "$TMP_DIR/$name.png" template
done

printf 'generated %d imagesets in %s\n' "${#generated[@]}" "$CATALOG_DIR"
printf '  %s\n' "${generated[@]}"

# A hand-edited Contents.json breaks the whole catalog at build time, so check
# that every file written above still parses as JSON when a parser is around.
if command -v python3 >/dev/null 2>&1; then
    for name in "${generated[@]}"; do
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
            "$CATALOG_DIR/$name.imageset/Contents.json" \
            || { echo "ERROR: invalid JSON in $name.imageset/Contents.json" >&2; exit 1; }
    done
fi
