#!/bin/sh
# ok() and bad() only count, and ok() always succeeds, so `check && ok || bad` is safe in this file.
# shellcheck disable=SC2015
# Tests for the SessionStart marker hook that `herdr-ccs install` writes (ccs-session-marker.sh), in both its
# forms: the Rust marker it execs when one was built, and its shell fallback. Installs into a temp HOME,
# CLAUDE_CONFIG_DIR and shim dir (nothing real is touched), then feeds the hook Claude Code-shaped input under
# sh, bash and dash, with no python3 on PATH, and from behind a fake `ccs` launcher for the profile.
# Usage: sh test/test_session_marker.sh   (from the repo root; the Rust half needs cargo, and is skipped without)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/herdr-ccs-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL [$mode] $1"; }

# A PATH with only the tools the hook needs, so a python3 call would fail.
mkdir -p "$T/nopy" "$T/fake"
for t in cat sed tr head ps mkdir awk; do
  p=$(command -v "$t") && ln -s "$p" "$T/nopy/$t"
done
# A fake ccs launcher: `ccs <args...>` runs the hook as its child, so the hook finds it among its parents.
# hop adds FAKE_DEPTH more shells in between, each a real parent process (no exec).
cat > "$T/fake/hop" <<'EOF'
#!/bin/sh
if [ "$1" -gt 0 ]; then "$0" $(($1 - 1)); exit $?; fi
"$HOOK_SHELL" "$HOOK"
exit $?
EOF
cat > "$T/fake/ccs" <<'EOF'
#!/bin/sh
"${0%/*}/hop" "${FAKE_DEPTH:-0}"
exit $?
EOF
chmod +x "$T/fake/hop" "$T/fake/ccs"

install() { # $1 = shell | rust
  rm -rf "${T:?}/home" "${T:?}/cfg" "${T:?}/shims"; mkdir -p "$T/home" "$T/cfg" "$T/shims"; : > "$T/home/.profile"
  printf '#!/bin/sh\nexit 0\n' > "$T/claude"; chmod +x "$T/claude"
  build=/nonexistent; [ "$1" = rust ] && build="$T/target/release/herdr-ccs-marker"
  HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" HERDR_CCS_SHIM_DIR="$T/shims" HERDR_CCS_PROFILE="$T/home/.profile" \
    HERDR_CCS_REAL_CLAUDE="$T/claude" HERDR_CCS_MARKER_BUILD="$build" sh "$ROOT/bin/herdr-ccs" install > "$T/install.log" 2>&1 \
    || { echo "FAIL [$1] install"; cat "$T/install.log"; exit 1; }
  HOOK="$T/cfg/hooks/ccs-session-marker.sh"; MARKS="$T/shims/ccs-sessions"
  export HOOK
}

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
via_ccs() { # $1 shell, $2 depth, then the fake ccs's own arguments
  sh_=$1; depth=$2; shift 2
  printf '{"session_id":"%s"}' "$ID" | env -u CCS_BROWSER_DEVTOOLS_HTTP_URL ANTHROPIC_AUTH_TOKEN=ccs-internal-managed \
    PATH="$T/nopy" HOOK_SHELL="$sh_" FAKE_DEPTH="$depth" "$T/fake/ccs" "$@"
}
marked() { [ -f "$MARKS/$1" ]; }
clean() { rm -f "$MARKS"/* 2>/dev/null; }
profile_is() { [ "$(sed -n 's/^profile=//p' "$MARKS/$ID" 2>/dev/null)" = "$1" ]; }

run_cases() {
  [ -x "$HOOK" ] && ok || bad "hook written"
  grep -v '^[[:space:]]*#' "$HOOK" | grep -q python && bad "hook still calls python" || ok
  for sh in /bin/sh /bin/bash /bin/dash; do
    [ -x "$sh" ] || continue
    clean
    hook "$sh" "{\"session_id\":\"$ID\",\"transcript_path\":\"/tmp/t.jsonl\",\"cwd\":\"/tmp\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
    marked "$ID" && ok || bad "$sh: compact input, no python on PATH"
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
    # The profile, read off the launching ccs process among the hook's parents.
    clean; via_ccs "$sh" 0 work --browser
    profile_is work && ok || bad "$sh: profile from the ccs parent"
    clean; via_ccs "$sh" 2 --verbose glm -n x
    profile_is glm && ok || bad "$sh: profile two shells up, flags skipped"
    clean; via_ccs "$sh" 0 'b@d' x
    marked "$ID" && profile_is '' && ok || bad "$sh: profile with other characters dropped"
    clean; via_ccs "$sh" 0 --only-flags
    marked "$ID" && profile_is '' && ok || bad "$sh: no profile argument"
    clean; via_ccs "$sh" 9 deep
    marked "$ID" && profile_is '' && ok || bad "$sh: ccs more than 8 parents up isn't searched"
  done
}

mode=shell; install shell
[ ! -e "$T/shims/bin/herdr-ccs-marker" ] && ok || bad "no Rust marker installed without a build"
run_cases
if command -v cargo >/dev/null 2>&1; then
  mode=rust
  cargo build -q --release --locked --manifest-path "$ROOT/marker/Cargo.toml" --target-dir "$T/target" || { echo "FAIL cargo build"; exit 1; }
  install rust
  [ -x "$T/shims/bin/herdr-ccs-marker" ] && ok || bad "Rust marker installed"
  grep -q 'marker: rust' "$T/install.log" && ok || bad "install reports the Rust marker"
  run_cases
  # Reinstalling without a build removes the copy, so hook and binary never come from different versions.
  mode=shell-again; install shell
  [ ! -e "$T/shims/bin/herdr-ccs-marker" ] && ok || bad "stale Rust marker removed"
else
  echo "skipped the Rust marker cases: no cargo"
fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
