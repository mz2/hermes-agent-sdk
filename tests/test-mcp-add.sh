#!/usr/bin/bash
# Tests bin/hermes-mcp-add: the helper that adds/updates/removes entries in the
# mcp_servers: block of ~/.hermes/config.yaml. Runs entirely on the host with a
# throwaway venv (PyYAML), no workshop required.
#
# Run: bash tests/test-mcp-add.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/../bin/hermes-mcp-add"

# --- provision a python with PyYAML (the in-workshop helper uses the hermes
# venv, which has it; here we build a disposable one) ---------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [ -n "${HERMES_PY:-}" ] && "$HERMES_PY" -c 'import yaml' 2>/dev/null; then
    PY="$HERMES_PY"
else
    python3 -m venv "$WORK/venv" >/dev/null
    "$WORK/venv/bin/pip" install --quiet pyyaml >/dev/null
    PY="$WORK/venv/bin/python"
fi
export HERMES_PY="$PY"

fail=0
check() {  # name  got  want
    if [ "$2" != "$3" ]; then echo "FAIL $1: got [$2] want [$3]"; fail=1; else echo "PASS $1"; fi
}
probe() {  # config-file  python-expr-over-cfg  ->  stdout
    "$PY" -c "import yaml; cfg=yaml.safe_load(open('$1')) or {}; print($2)" 2>/dev/null
}

# Each scenario gets a fresh HERMES_HOME with a seed config.yaml that has an
# unrelated top-level key (model) we expect to survive untouched.
new_home() {
    H="$WORK/home-$1"; mkdir -p "$H"
    printf 'model:\n  default: qwen3.6:35b\n  base_url: http://localhost:11434/v1\n' > "$H/config.yaml"
    echo "$H"
}
run() { HERMES_HOME="$1" "$HELPER" "${@:2}"; }   # run HOME args...

# 1. HTTP add: url + default tools scoping; unrelated key preserved -------
H="$(new_home http)"
run "$H" affine --url http://localhost:3000/mcp >/dev/null
check "http url"              "$(probe "$H/config.yaml" "cfg['mcp_servers']['affine']['url']")" "http://localhost:3000/mcp"
check "http resources=false"  "$(probe "$H/config.yaml" "cfg['mcp_servers']['affine']['tools']['resources']")" "False"
check "http prompts=false"    "$(probe "$H/config.yaml" "cfg['mcp_servers']['affine']['tools']['prompts']")" "False"
check "unrelated key kept"    "$(probe "$H/config.yaml" "cfg['model']['default']")" "qwen3.6:35b"

# 2. Header parsing ------------------------------------------------------
H="$(new_home header)"
run "$H" affine --url http://localhost:3000/mcp --header 'Authorization: Bearer ${TOK}' >/dev/null
check "header value"         "$(probe "$H/config.yaml" "cfg['mcp_servers']['affine']['headers']['Authorization']")" 'Bearer ${TOK}'

# 3. Update by name replaces, does not duplicate -------------------------
H="$(new_home update)"
run "$H" affine --url http://old:1/mcp >/dev/null
run "$H" affine --url http://new:2/mcp >/dev/null
check "update url"           "$(probe "$H/config.yaml" "cfg['mcp_servers']['affine']['url']")" "http://new:2/mcp"
check "single entry"         "$(probe "$H/config.yaml" "len(cfg['mcp_servers'])")" "1"

# 4. stdio: command + args + env + include -------------------------------
H="$(new_home stdio)"
run "$H" weather --command weather-mcp --arg --verbose --env API_KEY=xyz --include get_forecast >/dev/null
check "stdio command"        "$(probe "$H/config.yaml" "cfg['mcp_servers']['weather']['command']")" "weather-mcp"
check "stdio arg"            "$(probe "$H/config.yaml" "cfg['mcp_servers']['weather']['args'][0]")" "--verbose"
check "stdio env"            "$(probe "$H/config.yaml" "cfg['mcp_servers']['weather']['env']['API_KEY']")" "xyz"
check "stdio include"        "$(probe "$H/config.yaml" "cfg['mcp_servers']['weather']['tools']['include'][0]")" "get_forecast"

# 5. --keep-resources/--keep-prompts drop the tools scoping entirely ------
H="$(new_home keep)"
run "$H" plain --url http://x/mcp --keep-resources --keep-prompts >/dev/null
check "no tools block"       "$(probe "$H/config.yaml" "'tools' in cfg['mcp_servers']['plain']")" "False"

# 6. Remove an existing entry --------------------------------------------
H="$(new_home remove)"
run "$H" affine --url http://x/mcp >/dev/null
run "$H" affine --remove >/dev/null
check "removed entry"        "$(probe "$H/config.yaml" "'affine' in (cfg.get('mcp_servers') or {})")" "False"

# 7. Error cases (non-zero exit) -----------------------------------------
H="$(new_home errors)"
run "$H" ghost --remove >/dev/null 2>&1;                 check "remove missing -> error" "$?" "1"
run "$H" both --url u --command c >/dev/null 2>&1;        check "url+command -> error"    "$?" "1"
run "$H" neither >/dev/null 2>&1;                         check "no transport -> error"   "$?" "1"

# 8. Missing config.yaml is created --------------------------------------
H="$WORK/home-fresh"; mkdir -p "$H"   # no config.yaml seeded
run "$H" affine --url http://x/mcp >/dev/null
check "creates config"       "$(probe "$H/config.yaml" "cfg['mcp_servers']['affine']['url']")" "http://x/mcp"

# 9. --bearer-from copies a token into secrets/.env and sets the header ----
H="$(new_home bearer)"
SRC="$WORK/affine.env"; printf 'OTHER=1\nAFFINE_MCP_HTTP_TOKEN=secrettok\n' > "$SRC"
run "$H" affine --url http://localhost:3000/mcp --bearer-from "$SRC" --bearer-var AFFINE_MCP_HTTP_TOKEN >/dev/null
check "bearer header"        "$(probe "$H/config.yaml" "cfg['mcp_servers']['affine']['headers']['Authorization']")" 'Bearer ${AFFINE_MCP_HTTP_TOKEN}'
check "bearer secret stored" "$(grep -c '^AFFINE_MCP_HTTP_TOKEN=secrettok$' "$H/secrets/.env")" "1"

# 10. --bearer-from error cases ------------------------------------------
H="$(new_home bearer-err)"; SRC="$WORK/affine.env"
run "$H" affine --url http://x/mcp --bearer-from "$SRC" --bearer-var MISSING >/dev/null 2>&1
check "bearer var missing -> error"  "$?" "1"
run "$H" affine --url http://x/mcp --bearer-from "$SRC" >/dev/null 2>&1
check "bearer without var -> error"  "$?" "1"
run "$H" affine --command c --bearer-from "$SRC" --bearer-var AFFINE_MCP_HTTP_TOKEN >/dev/null 2>&1
check "bearer with command -> error" "$?" "1"
run "$H" affine --url http://x/mcp --bearer-from "$WORK/nope.env" --bearer-var X >/dev/null 2>&1
check "bearer file missing -> error" "$?" "1"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
