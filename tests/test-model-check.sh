#!/usr/bin/bash
# Tests the model.default extraction that hooks/check-health uses to decide
# whether to fail SDK health (empty -> set-health error). The awk here MUST
# stay identical to the one in hooks/check-health.
#
# Run: bash tests/test-model-check.sh
set -uo pipefail

extract() {
    awk '/^model:/{m=1;next} /^[^[:space:]]/{m=0} m && /^[[:space:]]*default:[[:space:]]*/{sub(/^[[:space:]]*default:[[:space:]]*/,"");gsub(/["'"'"']/,"");print;exit}'
}

fail=0
check() {  # name  got  want
    if [ "$2" != "$3" ]; then
        echo "FAIL $1: got [$2] want [$3]"; fail=1
    else
        echo "PASS $1"
    fi
}

UNSET=$'model:\n  provider: custom\n  default: ""\n  base_url: x\n'
SET=$'model:\n  provider: custom\n  default: qwen3.6:35b\n  base_url: x\n'
ELSEWHERE=$'agent:\n  default: nope\nmodel:\n  default: good\n'

check "empty default -> empty (health error)" "$(printf '%s' "$UNSET"    | extract)" ""
check "set default -> value (health ok)"      "$(printf '%s' "$SET"      | extract)" "qwen3.6:35b"
check "ignores default: outside model block"  "$(printf '%s' "$ELSEWHERE" | extract)" "good"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
