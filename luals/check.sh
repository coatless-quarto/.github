#!/bin/bash
# Type-check a folder of Lua filters against Quarto's Lua types with lua-language-server.
#
# usage: check.sh <dir> [Error|Warning|Information|Hint]   (default: Warning)
#        check.sh --self-test                              (must report 1 diagnostic)
#
# QUARTO=/path/to/bin/quarto picks the Quarto whose types are used (default: quarto on PATH).
# LUALS=/path/to/lua-language-server overrides the server (default: the VS Code sumneko.lua one).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LUALS=${LUALS:-$(ls -d "$HOME"/.vscode/extensions/sumneko.lua-*/server/bin/lua-language-server 2>/dev/null | tail -1)}
[ -x "$LUALS" ] || { echo "ERROR: lua-language-server not found; set LUALS=" >&2; exit 2; }
QBIN=$(command -v "${QUARTO:-quarto}") || { echo "ERROR: quarto not found; set QUARTO=" >&2; exit 2; }
QSHARE=$(cd "$(dirname "$(realpath "$QBIN")")/../share" && pwd)

if [ "${1:-}" = "--self-test" ]; then
  set -- "$HERE/canary" Hint
fi
DIR=$(cd "$1" && pwd); LVL=${2:-Warning}
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
cat > "$OUT/luarc.json" <<JSON
{
  "runtime.version": "Lua 5.4",
  "runtime.plugin": "$QSHARE/lua-plugin/plugin.lua",
  "workspace.library": ["$QSHARE/lua-types"],
  "workspace.checkThirdParty": false,
  "diagnostics.disable": ["lowercase-global", "trailing-space"],
  "diagnostics.globals": ["quarto", "pandoc", "PANDOC_VERSION", "PANDOC_STATE", "FORMAT",
    "PANDOC_READER_OPTIONS", "PANDOC_WRITER_OPTIONS", "PANDOC_SCRIPT_FILE", "PANDOC_API_VERSION", "lpeg", "re"]
}
JSON
# LuaLS 3.19 needs --check_format/--check_out_path; without them it silently reports nothing.
"$LUALS" --check="$DIR" --configpath="$OUT/luarc.json" --checklevel="$LVL" --logpath="$OUT/log" \
  --check_format=json --check_out_path="$OUT/check.json" >/dev/null 2>&1
[ -f "$OUT/check.json" ] || { echo "ERROR: lua-language-server wrote no check.json" >&2; exit 2; }
python3 -I - "$OUT/check.json" <<'PY'
import json, sys, urllib.parse
d = json.load(open(sys.argv[1]))
if isinstance(d, list):
    d = {}
n = 0
for uri, diags in sorted(d.items()):
    p = urllib.parse.unquote(uri.replace("file://", ""))
    for x in diags:
        n += 1
        print(f"{p}:{x['range']['start']['line'] + 1}: [{x.get('code')}] {x['message'].splitlines()[0]}")
print(f"TOTAL {n}")
sys.exit(1 if n else 0)
PY
