#!/bin/bash
# Exercises bin/wave3-reset and bin/wave3-watch against a stub pactl on PATH.
# Never touches the real audio server.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CARD="alsa_card.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00"
SRC="alsa_input.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.mono-fallback"
OTHER="alsa_input.usb-046d_MX_Brio_TEST-04.analog-stereo"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/pactl" <<'STUB'
#!/bin/bash
# State lives in $STUB: card/source files mark presence, the rest hold values.
echo "pactl $*" >> "$STUB/log"
case "$1 ${2:-}" in
  "list short")
    if [ "$3" = cards ]; then
      echo "50	alsa_card.pci-0000_0d_00.4	alsa"
      [ -f "$STUB/card" ] && echo "48	$(cat "$STUB/card")	alsa"
    else
      echo "34	$OTHER	PipeWire	s16le 2ch 48000Hz	SUSPENDED"
      [ -f "$STUB/source" ] && echo "61	$(cat "$STUB/source")	PipeWire	s24le 1ch 48000Hz	SUSPENDED"
      [ -f "$STUB/card" ] && echo "60	alsa_output.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.analog-stereo.monitor	PipeWire	s24le 2ch 48000Hz	SUSPENDED"
    fi ;;
  "list cards")
    [ -f "$STUB/card" ] && printf 'Card #48\n\tName: %s\n\tActive Profile: %s\n' "$(cat "$STUB/card")" "$(cat "$STUB/profile")" ;;
  "get-default-source "*) cat "$STUB/default" ;;
  "get-source-mute "*) echo "Mute: $(cat "$STUB/muted")" ;;
  "set-default-source "*) echo "$2" > "$STUB/default" ;;
  "set-source-mute "*) [ "$3" = 0 ] && echo no > "$STUB/muted" || echo yes > "$STUB/muted" ;;
  "set-card-profile "*) echo "$3" > "$STUB/profile" ;;
  "subscribe ") cat "$STUB/events" ;;
  *) echo "stub pactl: unexpected: $*" >&2; exit 2 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/pactl"
export PATH="$TMP/bin:$PATH" OTHER STUB="$TMP/state" WAVE3_WAIT_TRIES=2

fails=0
pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi }

# fresh <present:yes|no> [default] [muted]
fresh() {
  rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/log"
  echo "${2:-$OTHER}" > "$STUB/default"
  echo "${3:-yes}" > "$STUB/muted"
  echo "output:analog-stereo+input:mono-fallback" > "$STUB/profile"
  if [ "$1" = yes ]; then echo "$CARD" > "$STUB/card"; echo "$SRC" > "$STUB/source"; fi
}
calls() { grep -v -e ' list ' -e ' get-' "$STUB/log" || true; }

# --- absent mic ---
fresh no
set +e; err="$("$ROOT/bin/wave3-reset" 2>&1 >/dev/null)"; rc=$?; set -e
check "absent: reset exits non-zero" '[ "$rc" -ne 0 ]'
check "absent: reset explains on stderr" '[[ "$err" == *"Wave:3 not found"* ]]'
check "absent: nothing was changed" '[ -z "$(calls)" ]'
set +e; "$ROOT/bin/wave3-reset" --default-only 2>/dev/null; rc=$?; set -e
check "absent: --default-only exits non-zero" '[ "$rc" -ne 0 ]'
out="$("$ROOT/bin/wave3-reset" --status)"
check "absent: --status reports absent and exits 0" '[[ "$out" == *"present=no"* && "$out" == *"state=absent"* ]]'

# --- present, not default, muted ---
fresh yes
out="$("$ROOT/bin/wave3-reset" --status)"
check "present: --status fields" '[[ "$out" == *"present=yes"* && "$out" == *"default=no"* && "$out" == *"muted=yes"* && "$out" == *"state=SUSPENDED"* && "$out" == *"source=$SRC"* && "$out" == *"profile=output:analog-stereo+input:mono-fallback"* ]]'
check "present: --status changes nothing" '[ -z "$(calls)" ]'

"$ROOT/bin/wave3-reset" >/dev/null
expected="pactl set-card-profile $CARD output:iec958-stereo+input:mono-fallback
pactl set-card-profile $CARD output:analog-stereo+input:mono-fallback
pactl set-default-source $SRC
pactl set-source-mute $SRC 0"
check "present: reset toggles digital, back to analog, then defaults and unmutes" '[ "$(calls)" = "$expected" ]'
out="$("$ROOT/bin/wave3-reset" --status)"
check "present: now default and unmuted" '[[ "$out" == *"default=yes"* && "$out" == *"muted=no"* ]]'

# --- idempotent ---
: > "$STUB/log"
"$ROOT/bin/wave3-reset" --default-only >/dev/null
check "idempotent: --default-only on an ok mic changes nothing" '[ -z "$(calls)" ]'
: > "$STUB/log"
"$ROOT/bin/wave3-reset" >/dev/null
check "idempotent: second reset only toggles the profile" '[ "$(calls)" = "$(printf "%s\n" "$expected" | head -2)" ]'
check "idempotent: ends on the analog profile" '[ "$(cat "$STUB/profile")" = output:analog-stereo+input:mono-fallback ]'

fresh yes
"$ROOT/bin/wave3-reset" --default-only >/dev/null
check "--default-only never touches the profile" '! calls | grep -q set-card-profile && calls | grep -q "set-default-source $SRC"'

# --- source does not come back ---
fresh yes; rm "$STUB/source"
set +e; err="$("$ROOT/bin/wave3-reset" 2>&1 >/dev/null)"; rc=$?; set -e
check "lost source: reset gives up with a message" '[ "$rc" -ne 0 ] && [[ "$err" == *"did not come back"* ]]'

# --- watcher ---
cat > "$TMP/fake-reset" <<'EOF'
#!/bin/bash
echo "reset $*" >> "$STUB/resets"
EOF
chmod +x "$TMP/fake-reset"
fresh yes
cat > "$STUB/events" <<'EOF'
Event 'change' on server #0
Event 'change' on source #61
Event 'new' on source #70
Event 'remove' on source #61
Event 'new' on card #48
Event 'new' on sink-input #90
EOF
set +e; WAVE3_RESET="$TMP/fake-reset" "$ROOT/bin/wave3-watch" 2>"$TMP/watch.err"; rc=$?; set -e
check "watch: runs at start and once per new source/card event only" '[ "$(cat "$STUB/resets")" = "$(printf "reset --default-only\n%.0s" 1 2 3)" ]'
check "watch: exits non-zero when the subscription ends" '[ "$rc" -ne 0 ] && grep -q "subscribe ended" "$TMP/watch.err"'

# Symlinked into another dir, the watcher still finds its sibling wave3-reset.
ln -s "$ROOT/bin/wave3-watch" "$TMP/bin/wave3-watch"
fresh yes; : > "$STUB/events"
set +e; "$TMP/bin/wave3-watch" 2>/dev/null; set -e
check "watch: symlinked copy resolves sibling reset and defaults the mic" 'calls | grep -q "set-default-source $SRC"'

[ "$fails" -eq 0 ] || { echo "$fails test(s) failed"; exit 1; }
echo "all script tests passed"
