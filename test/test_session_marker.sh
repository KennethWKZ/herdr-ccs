#!/bin/sh
# ok() and bad() only count, and ok() always succeeds, so `check && ok || bad` is safe in this file.
# shellcheck disable=SC2015
# Tests for the SessionStart marker hook that `herdr-ccs install` writes (ccs-session-marker.sh).
# Installs into a temp HOME, CLAUDE_CONFIG_DIR and shim dir (nothing real is touched), then feeds the hook
# Claude Code-shaped input under sh and bash, including a PATH with no python3 at all.
# Usage: sh test/test_session_marker.sh        (from the repo root; needs python3 only for install itself)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/herdr-ccs-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/cfg" "$T/shims" "$T/nopy"
: > "$T/home/.profile"
printf '#!/bin/sh\nexit 0\n' > "$T/claude"; chmod +x "$T/claude"
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" HERDR_CCS_SHIM_DIR="$T/shims" HERDR_CCS_PROFILE="$T/home/.profile" \
  HERDR_CCS_REAL_CLAUDE="$T/claude" sh "$ROOT/bin/herdr-ccs" install > "$T/install.log" 2>&1 \
  || { echo "FAIL install"; cat "$T/install.log"; exit 1; }
HOOK="$T/cfg/hooks/ccs-session-marker.sh"
MARKS="$T/shims/ccs-sessions"
[ -x "$HOOK" ] && ok || bad "hook written"
grep -v '^[[:space:]]*#' "$HOOK" | grep -q python && bad "hook still calls python" || ok

# A PATH with only the tools the hook needs, so a python3 call would fail.
for t in cat sed tr head ps mkdir; do
  p=$(command -v "$t") && ln -s "$p" "$T/nopy/$t"
done

ID=1a2b3c4d-0000-4000-8000-00000000abcd
# Options are arguments, not VAR=x prefixes: POSIX sh keeps a prefix assignment to a function call set afterwards.
hook() { # $1 shell, $2 input, $3 token|notoken (default token), $4 browser DevTools URL (optional)
  if [ "${3:-token}" = notoken ]; then
    printf '%s' "$2" | env -u ANTHROPIC_AUTH_TOKEN -u CCS_BROWSER_DEVTOOLS_HTTP_URL PATH="$T/nopy" "$1" "$HOOK"
  elif [ -n "${4:-}" ]; then
    printf '%s' "$2" | env ANTHROPIC_AUTH_TOKEN=ccs-internal-managed CCS_BROWSER_DEVTOOLS_HTTP_URL="$4" PATH="$T/nopy" "$1" "$HOOK"
  else
    printf '%s' "$2" | env -u CCS_BROWSER_DEVTOOLS_HTTP_URL ANTHROPIC_AUTH_TOKEN=ccs-internal-managed PATH="$T/nopy" "$1" "$HOOK"
  fi
}
marked() { [ -f "$MARKS/$1" ]; }
clean() { rm -f "$MARKS"/* 2>/dev/null; }

for sh in /bin/sh /bin/bash /bin/dash; do
  [ -x "$sh" ] || continue
  clean
  hook "$sh" "{\"session_id\":\"$ID\",\"transcript_path\":\"/tmp/t.jsonl\",\"cwd\":\"/tmp\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  marked "$ID" && ok || bad "$sh: compact input, no python on PATH"
  # The profile line depends on whether a ccs process is among the test's own parents; no browser line here.
  grep -qx 'browser=1' "$MARKS/$ID" 2>/dev/null && bad "$sh: browser=1 without a DevTools URL" || ok
  clean
  hook "$sh" "$(printf '{\n  "hook_event_name": "SessionStart",\n  "session_id" : "%s",\n  "cwd": "/tmp"\n}\n' "$ID")"
  marked "$ID" && ok || bad "$sh: pretty-printed input, key not first"
  clean
  hook "$sh" "{\"session_id\":\"$ID\"}" token http://127.0.0.1:9222
  grep -qx 'browser=1' "$MARKS/$ID" 2>/dev/null && ok || bad "$sh: browser=1 recorded"
  clean
  hook "$sh" "{\"session_id\":\"$ID\"}" notoken
  [ -z "$(ls -A "$MARKS")" ] && ok || bad "$sh: native session (no ccs token) not tagged"
  # The id names a file: anything but a UUID-like id is refused, so nothing lands outside MARK_DIR.
  for evil in '../../escape' 'a/b' '.hidden' 'x y' ''; do
    clean
    hook "$sh" "{\"session_id\":\"$evil\"}"
    [ -z "$(ls -A "$MARKS")" ] && [ ! -e "$T/escape" ] && ok || bad "$sh: id '$evil' refused"
  done
  # A session_id written inside another string value is not the key.
  clean
  hook "$sh" "{\"cwd\":\"/tmp/a\\\",\\\"session_id\\\":\\\"fake-id\",\"session_id\":\"$ID\"}"
  marked "$ID" && ! marked fake-id && ok || bad "$sh: escaped key inside a value ignored"
  clean
  hook "$sh" "{\"cwd\":\"x \\\"session_id\\\":\\\"fake-id\\\"\"}"
  [ -z "$(ls -A "$MARKS")" ] && ok || bad "$sh: only an escaped key -> no marker"
  clean
  hook "$sh" 'not json'
  [ -z "$(ls -A "$MARKS")" ] && ok || bad "$sh: garbage input"
  if hook "$sh" ''; then ok; else bad "$sh: exit 0 on empty input"; fi
done

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
