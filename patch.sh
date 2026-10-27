#!/bin/bash
# ──────────────────────────────────────────────────────────────────
# Claude Extension Arc Browser Patcher
# Takes the official Claude Chrome extension and patches it
# to work with Arc browser using a floating panel.
# ──────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLOATING_PANEL_JS="$SCRIPT_DIR/floating-panel.js"
SW_PATCH_JS="$SCRIPT_DIR/sw-patch.js"
ARC_TABS_PATCH_JS="$SCRIPT_DIR/arc-tabs-patch.js"
ARC_TABGROUPS_SHIM_JS="$SCRIPT_DIR/arc-tabgroups-shim.js"
ARC_COWORK_PATCH_JS="$SCRIPT_DIR/arc-cowork-patch.js"
ARC_PROFILE_NAMES_PY="$SCRIPT_DIR/arc-profile-names.py"

# --rename: also replace connection names chosen by hand in the pairing prompt
RENAME_PROFILES=""
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --rename) RENAME_PROFILES="--rename" ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# ── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# ── Find Claude Extension ───────────────────────────────────────

find_claude_extension() {
  shopt -s nullglob

  # Browser profile roots. Only the profile dir and version dir are globbed (the
  # unquoted *); the space-containing parts stay quoted so paths such as
  # "Application Support" / "User Data" are not split on their spaces.
  local roots=()
  if [[ "$OSTYPE" == "darwin"* ]]; then
    roots+=(
      "$HOME/Library/Application Support/Google/Chrome"
      "$HOME/Library/Application Support/Arc/User Data"
    )
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    roots+=(
      "$HOME/.config/google-chrome"
      "$HOME/.config/chromium"
    )
  fi

  # Claude extension known IDs
  local claude_ids=("jlgadfahkiakjhceomgpemiabkpgnlho" "cpklelfgbalgamlgfhikjfneldeeilcg" "fcoeoabgfenejglbffodgkkbkcdhcgfn")

  # Collect every installed version dir across profiles, then keep the highest version.
  local best=""
  for root in "${roots[@]}"; do
    for ext_id in "${claude_ids[@]}"; do
      for ver_dir in "$root"/*/Extensions/"$ext_id"/*/; do
        [ -f "${ver_dir}manifest.json" ] || continue
        local cand="${ver_dir%/}"
        if [ -z "$best" ]; then
          best="$cand"
        elif [ "$(printf '%s\n%s\n' "${best##*/}" "${cand##*/}" | sort -V | tail -1)" = "${cand##*/}" ]; then
          best="$cand"
        fi
      done
    done
  done

  [ -n "$best" ] || return 1
  echo "$best"
  return 0
}

# ── Main ─────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Claude Extension - Arc Browser Patcher     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# Check required files
[ -f "$FLOATING_PANEL_JS" ] || fail "floating-panel.js not found in $SCRIPT_DIR"
[ -f "$SW_PATCH_JS" ] || fail "sw-patch.js not found in $SCRIPT_DIR"
[ -f "$ARC_TABS_PATCH_JS" ] || fail "arc-tabs-patch.js not found in $SCRIPT_DIR"
[ -f "$ARC_TABGROUPS_SHIM_JS" ] || fail "arc-tabgroups-shim.js not found in $SCRIPT_DIR"
[ -f "$ARC_COWORK_PATCH_JS" ] || fail "arc-cowork-patch.js not found in $SCRIPT_DIR"
[ -f "$ARC_PROFILE_NAMES_PY" ] || fail "arc-profile-names.py not found in $SCRIPT_DIR"

# Find or accept source path
SOURCE_DIR=""

if [ -n "$1" ]; then
  SOURCE_DIR="$1"
  [ -d "$SOURCE_DIR" ] || fail "Provided path does not exist: $SOURCE_DIR"
  [ -f "$SOURCE_DIR/manifest.json" ] || fail "No manifest.json found in: $SOURCE_DIR"
else
  info "Searching for Claude extension..."
  SOURCE_DIR=$(find_claude_extension) || true

  if [ -z "$SOURCE_DIR" ]; then
    echo ""
    warn "Could not auto-detect Claude extension."
    echo ""
    echo "Please provide the path manually. You can find it by:"
    echo "  1. Open chrome://extensions in Chrome"
    echo "  2. Enable Developer Mode"
    echo "  3. Find 'Claude' and note the extension ID"
    echo "  4. The extension is at:"
    echo "     macOS: ~/Library/Application Support/Google/Chrome/Default/Extensions/<ID>/<version>"
    echo ""
    echo "Usage: $0 [--rename] [/path/to/claude/extension]"
    exit 1
  fi
fi

ok "Found Claude extension at: $SOURCE_DIR"

# Create output directory
OUTPUT_DIR="$SCRIPT_DIR/claude-arc-patched"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

info "Copying extension files..."
cp -R "$SOURCE_DIR/"* "$OUTPUT_DIR/"
chmod -R u+rw "$OUTPUT_DIR"
ok "Files copied to: $OUTPUT_DIR"

# Copy floating panel
info "Adding floating-panel.js..."
cp "$FLOATING_PANEL_JS" "$OUTPUT_DIR/floating-panel.js"
ok "floating-panel.js added"

# Copy service worker patch
info "Adding sw-patch.js..."
cp "$SW_PATCH_JS" "$OUTPUT_DIR/sw-patch.js"
ok "sw-patch.js added"

# Copy tab groups shim (emulates the Chrome Tab Groups API, which Arc exposes
# but never resolves — see README "How It Works")
info "Adding arc-tabgroups-shim.js..."
cp "$ARC_TABGROUPS_SHIM_JS" "$OUTPUT_DIR/arc-tabgroups-shim.js"
ok "arc-tabgroups-shim.js added"

# ── Patch sidepanel.html ─────────────────────────────────────────
# Two jobs: (1) if the extension still ships an inline theme <script>, move it to an
# external file (Manifest V3 CSP forbids inline scripts); (2) inject arc-tabs-patch.js
# so chrome.tabs.query is patched before the sidepanel bundle runs. Job 2 must NOT
# depend on job 1 — newer versions dropped the inline theme script entirely.

info "Preparing theme-init.js (used only if this version ships an inline theme script)..."
cat > "$OUTPUT_DIR/theme-init.js" << 'THEMEJS'
(function () {
  const isDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  document.documentElement.setAttribute("data-mode", isDark ? "dark" : "light");
  window
    .matchMedia("(prefers-color-scheme: dark)")
    .addEventListener("change", (e) => {
      document.documentElement.setAttribute(
        "data-mode",
        e.matches ? "dark" : "light"
      );
    });
})();
THEMEJS

info "Adding arc-tabs-patch.js..."
cp "$ARC_TABS_PATCH_JS" "$OUTPUT_DIR/arc-tabs-patch.js"

# Copy cowork patch (forces the classic sidepanel; the newer "cowork" experience
# embeds a claude.ai iframe that Arc's frame-ancestors refuses — see README)
info "Adding arc-cowork-patch.js..."
cp "$ARC_COWORK_PATCH_JS" "$OUTPUT_DIR/arc-cowork-patch.js"

info "Patching sidepanel.html..."
OUTPUT_DIR="$OUTPUT_DIR" python3 << 'PYEOF'
import re, os

out = os.environ["OUTPUT_DIR"]
path = os.path.join(out, "sidepanel.html")
with open(path) as f:
    html = f.read()

# (1) Extract inline theme script to an external file if present (older versions).
m = re.search(r"<script>\s*//\s*Set initial theme.*?</script>", html, flags=re.DOTALL)
if m:
    html = html.replace(m.group(0), '<script src="/theme-init.js"></script>')
else:
    # Newer versions theme inside the bundle; drop the unused generated file.
    tj = os.path.join(out, "theme-init.js")
    if os.path.exists(tj):
        os.remove(tj)

# (2) Inject our classic scripts before the first <script> so they run before the
#     sidepanel bundle. A classic script executes before the deferred module bundle
#     regardless of position. Anchored on <script>, not on the theme tag, so it
#     survives future markup changes. Each injection is idempotent.
#       - arc-tabs-patch.js:   patch chrome.tabs.query for the iframe context.
#       - arc-cowork-patch.js: force the classic sidepanel (the newer "cowork"
#         experience embeds a claude.ai iframe that Arc's frame-ancestors refuses).
def inject_before_first_script(html, src):
    if src in html:
        return html
    tag = '<script src="/%s"></script>\n    ' % src
    idx = html.find("<script")
    if idx != -1:
        return html[:idx] + tag + html[idx:]
    return html.replace("</head>", "    " + tag + "</head>")

html = inject_before_first_script(html, "arc-tabs-patch.js")
html = inject_before_first_script(html, "arc-cowork-patch.js")
# The in-panel agent's tools (tabs_create, navigate, ...) execute inside the
# sidepanel page, so the Tab Groups shim must be present there too — it must
# load first so arc-tabs-patch.js wraps the shimmed chrome.tabs.query.
html = inject_before_first_script(html, "arc-tabgroups-shim.js")

with open(path, "w") as f:
    f.write(html)

# Fail loudly if a critical patch did not land — never report success silently.
assert "arc-tabs-patch.js" in html, "FAILED to inject arc-tabs-patch.js into sidepanel.html"
assert "arc-cowork-patch.js" in html, "FAILED to inject arc-cowork-patch.js into sidepanel.html"
assert "arc-tabgroups-shim.js" in html, "FAILED to inject arc-tabgroups-shim.js into sidepanel.html"
print("OK")
PYEOF
ok "sidepanel.html patched (arc-tabgroups-shim.js + arc-tabs-patch.js + arc-cowork-patch.js injected)"

# ── Patch manifest.json ─────────────────────────────────────────

info "Patching manifest.json..."

# Use Python for reliable JSON manipulation
OUTPUT_DIR="$OUTPUT_DIR" python3 << 'PYEOF'
import json
import sys
import os

manifest_path = os.path.join(os.environ["OUTPUT_DIR"], "manifest.json")

with open(manifest_path, "r") as f:
    manifest = json.load(f)

# Add floating-panel.js as content script
content_scripts = manifest.get("content_scripts", [])

# Check if already patched
already_patched = any(
    "floating-panel.js" in cs.get("js", [])
    for cs in content_scripts
)

if not already_patched:
    content_scripts.append({
        "matches": ["<all_urls>"],
        "exclude_matches": [
            "https://claude.ai/*",
            "https://*.claude.ai/*"
        ],
        "js": ["floating-panel.js"],
        "run_at": "document_idle",
        "all_frames": False
    })
    manifest["content_scripts"] = content_scripts

# Ensure sidepanel.html is web_accessible
war = manifest.get("web_accessible_resources", [])
sidepanel_accessible = any(
    "sidepanel.html" in r.get("resources", [])
    for r in war if isinstance(r, dict)
)
if not sidepanel_accessible:
    war.append({
        "resources": ["sidepanel.html"],
        "matches": ["<all_urls>"]
    })
    manifest["web_accessible_resources"] = war

# Patch service worker background to also load sw-patch.js
bg = manifest.get("background", {})
if bg.get("service_worker") == "sw-loader.js":
    # Source is already a patched output (e.g. re-patching claude-arc-patched
    # itself because the vanilla copy is gone). Without this guard the loader
    # would be rewritten to import itself and the real bundle would never load.
    print("manifest already points at sw-loader.js; leaving loaders untouched")
elif bg.get("service_worker"):
    # Replace single service worker with a loader that imports both
    original_sw = bg["service_worker"]
    bg["service_worker"] = "sw-loader.js"
    bg["type"] = "module"
    manifest["background"] = bg

    # Write the loader
    loader_path = os.path.join(os.environ["OUTPUT_DIR"], "sw-loader.js")
    with open(loader_path, "w") as f:
        f.write(f'// Patch sidePanel API BEFORE loading original service worker\n')
        f.write(f'import "./sw-patch.js";\n')
        f.write(f'// Emulate the Chrome Tab Groups API (Arc exposes it but it hangs)\n')
        f.write(f'import "./arc-tabgroups-shim.js";\n')
        f.write(f'import "./{original_sw}";\n')

    # Also make the ORIGINAL entry point load the patches. Arc has been seen to
    # keep using the manifest it parsed at first load (service_worker still
    # pointing at the original loader) even after "Reload", which left every
    # patch inert. ES modules are only evaluated once, so importing the patch
    # files from both loaders is safe.
    orig_path = os.path.join(os.environ["OUTPUT_DIR"], original_sw)
    with open(orig_path, "r") as f:
        orig_src = f.read()
    if "sw-patch.js" not in orig_src:
        with open(orig_path, "w") as f:
            f.write('// Arc may keep using this entry point even after the manifest is patched\n')
            f.write('// (it does not always re-parse manifest.json on Reload), so load the Arc\n')
            f.write('// patches from here as well.\n')
            f.write('import "./sw-patch.js";\n')
            f.write('import "./arc-tabgroups-shim.js";\n')
            f.write(orig_src)

# Remove side_panel key if present (not supported in Arc)
if "side_panel" in manifest:
    del manifest["side_panel"]


with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2)

print("OK")
PYEOF

ok "manifest.json patched"

# ── Name each Arc profile's connection ──────────────────────────
# Every Arc profile running the extension shows up in Claude as a separate
# browser with the same default name ("Browser 1..N"). Read each profile's
# connection id from its own extension storage (read-only) and map it to the
# profile name; sw-patch.js applies it. Profiles that never ran the extension
# have no id yet: re-run patch.sh after loading it there once.

if [[ "$OSTYPE" == "darwin"* ]]; then
  info "Naming Arc profile connections..."
  if python3 "$ARC_PROFILE_NAMES_PY" "$OUTPUT_DIR/arc-profile-names.json" $RENAME_PROFILES; then
    ok "arc-profile-names.json written"
  else
    warn "Could not read Arc profile connections; connections keep their default names"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Patch Complete!                     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "Patched extension is at:"
echo -e "  ${CYAN}$OUTPUT_DIR${NC}"
echo ""
echo "To install in Arc:"
echo "  1. Open arc://extensions"
echo "  2. Enable 'Developer mode' (top right)"
echo "  3. Click 'Load unpacked'"
echo "  4. Select: $OUTPUT_DIR"
echo "  5. Press Cmd+E (Mac) or Ctrl+E to toggle Claude panel"
echo ""
echo "Each Arc profile's connection is named after the profile (e.g. \"Arc – Work\")"
echo "once the extension reconnects there. Run with --rename to also replace names"
echo "picked by hand in the pairing prompt."
echo ""
echo -e "${YELLOW}Note: Disable the original Claude extension to avoid conflicts.${NC}"
echo ""
