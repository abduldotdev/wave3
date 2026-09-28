#!/bin/bash
# Exercises bin/wave3-reset, bin/wave3-meter and bin/wave3-watch against stub
# pactl and parec binaries on PATH. Never touches the real audio server.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CARD="alsa_card.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00"
SRC="alsa_input.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.mono-fallback"
SINK="alsa_output.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.analog-stereo"
OTHER="alsa_input.usb-046d_MX_Brio_TEST-04.analog-stereo"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/pactl" <<'STUB'
#!/bin/bash
# State lives in $STUB: card/source files mark presence, the rest hold values.
echo "pactl $*" >> "$STUB/log"
[ -f "$STUB/down" ] && { echo "Connection failure: Connection refused" >&2; exit 1; }
case "$1 ${2:-}" in
  "list short")
    if [ "$3" = cards ]; then
      echo "50	alsa_card.pci-0000_0d_00.4	alsa"
      [ -f "$STUB/card" ] && echo "48	$(cat "$STUB/card")	alsa"
    elif [ "$3" = sinks ]; then
      echo "33	alsa_output.pci-0000_0d_00.4.analog-stereo	PipeWire	s16le 2ch 48000Hz	SUSPENDED"
      [ -f "$STUB/sink" ] && echo "53	$(cat "$STUB/sink")	PipeWire	s24le 2ch 48000Hz	RUNNING"
    else
      echo "34	$OTHER	PipeWire	s16le 2ch 48000Hz	SUSPENDED"
      [ -f "$STUB/source" ] && echo "$(cat "$STUB/srcidx")	$(cat "$STUB/source")	PipeWire	s24le 1ch 48000Hz	SUSPENDED"
      [ -f "$STUB/card" ] && echo "60	alsa_output.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.analog-stereo.monitor	PipeWire	s24le 2ch 48000Hz	SUSPENDED"
    fi ;;
  "list cards")
    [ -f "$STUB/card" ] && printf 'Card #48\n\tName: %s\n\tActive Profile: %s\n' "$(cat "$STUB/card")" "$(cat "$STUB/profile")" ;;
  "get-default-source "*) cat "$STUB/default" ;;
  "get-source-mute "*) echo "Mute: $(cat "$STUB/muted")" ;;
  "get-source-volume "*)
    v="$(cat "$STUB/volume")"
    echo "Volume: mono: $((v * 655)) / ${v}% / 0.00 dB" ;;
  "get-sink-volume "*)
    l="$(cat "$STUB/sink_volume")"
    if [ -f "$STUB/sink_volume_r" ]; then r="$(cat "$STUB/sink_volume_r")"; else r="$l"; fi
    echo "Volume: front-left: $((l * 655)) / ${l}% / -20.81 dB,   front-right: $((r * 655)) / ${r}% / -20.81 dB" ;;
  "get-sink-mute "*) echo "Mute: $(cat "$STUB/sink_muted")" ;;
  "set-default-source "*) [ -f "$STUB/vanish" ] && { echo "Failure: No such entity" >&2; exit 1; }; echo "$2" > "$STUB/default" ;;
  "set-source-mute "*) [ "$3" = 0 ] && echo no > "$STUB/muted" || echo yes > "$STUB/muted" ;;
  # A profile switch recreates the source under a new index unless keep-index.
  "set-card-profile "*) echo "$3" > "$STUB/profile"
    [ -f "$STUB/keep-index" ] || echo $(($(cat "$STUB/srcidx") + 1)) > "$STUB/srcidx" ;;
  "subscribe ") cat "$STUB/events" ;;
  *) echo "stub pactl: unexpected: $*" >&2; exit 2 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/pactl"
# Three 800-sample chunks: silence, +32767, and -32768 (clamped to 32767).
# $STUB/parec-forever loops a chunk instead, so a signal test can catch it.
cat > "$TMP/bin/parec" <<'STUB'
#!/bin/bash
echo "parec $*" >> "$STUB/parec.log"
if [ -f "$STUB/parec-forever" ]; then
  while true; do
    dd if=/dev/zero bs=1600 count=1 status=none
    sleep 0.05
  done
fi
dd if=/dev/zero bs=1600 count=1 status=none
printf '\377\177%.0s' $(seq 1 800)
printf '\000\200%.0s' $(seq 1 800)
STUB
chmod +x "$TMP/bin/parec"
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
  echo 61 > "$STUB/srcidx"
  echo 100 > "$STUB/volume"
  echo 45 > "$STUB/sink_volume"
  echo no > "$STUB/sink_muted"
  # The headphone sink is present exactly when the card is.
  if [ "$1" = yes ]; then
    echo "$CARD" > "$STUB/card"
    echo "$SRC" > "$STUB/source"
    echo "$SINK" > "$STUB/sink"
  fi
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
expected="$(cat <<EOF
present=no
default=no
muted=no
state=absent
profile=
volume=
sink=
sink_volume=
sink_muted=no
EOF
)"
check "absent: --status is the empty shape" '[ "$out" = "$expected" ]'

# --- present, not default, muted ---
fresh yes
out="$("$ROOT/bin/wave3-reset" --status)"
check "present: --status fields" '[[ "$out" == *"present=yes"* && "$out" == *"default=no"* && "$out" == *"muted=yes"* && "$out" == *"state=SUSPENDED"* && "$out" == *"source=$SRC"* && "$out" == *"profile=output:analog-stereo+input:mono-fallback"* ]]'
check "present: --status changes nothing" '[ -z "$(calls)" ]'
# fresh leaves the mic not-default and muted; every other line is the fixture.
expected="$(cat <<EOF
present=yes
default=no
muted=yes
state=SUSPENDED
profile=output:analog-stereo+input:mono-fallback
source=$SRC
volume=100
sink=$SINK
sink_volume=45
sink_muted=no
EOF
)"
check "present: --status matches the level fixture" '[ "$out" = "$expected" ]'
check "present: --status makes no set-* calls" '! grep -q " set-" "$STUB/log"'

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

# --- source index ---
fresh yes
"$ROOT/bin/wave3-reset" >/dev/null 2>"$TMP/err"
check "index: each profile switch sees a recreated source (61 -> 63), no warning" '[ "$(cat "$STUB/srcidx")" = 63 ] && [ ! -s "$TMP/err" ]'
fresh yes; touch "$STUB/keep-index"
set +e; "$ROOT/bin/wave3-reset" >/dev/null 2>"$TMP/err"; rc=$?; set -e
check "index: an unchanged index waits, warns, and still defaults the mic" '[ "$rc" -eq 0 ] && grep -q "was not recreated" "$TMP/err" && [ "$(cat "$STUB/default")" = "$SRC" ]'

# --- transient failures ---
fresh yes; touch "$STUB/vanish"
set +e; err="$("$ROOT/bin/wave3-reset" --default-only 2>&1 >/dev/null)"; rc=$?; set -e
check "vanish: missing source at set-default fails with a wave3-reset message" '[ "$rc" -ne 0 ] && [[ "$err" == "wave3-reset: "*"disappeared before it could be made default"* ]]'
fresh yes; touch "$STUB/down"
set +e; out="$("$ROOT/bin/wave3-reset" --status 2>/dev/null)"; rc=$?; set -e
check "server down: --status exits 0 with the absent shape" '[ "$rc" -eq 0 ] && [[ "$out" == *"present=no"* && "$out" == *"state=absent"* ]]'
expected="$(cat <<EOF
present=no
default=no
muted=no
state=absent
profile=
volume=
sink=
sink_volume=
sink_muted=no
EOF
)"
check "server down: --status is the empty shape" '[ "$rc" -eq 0 ] && [ "$out" = "$expected" ]'
set +e; err="$("$ROOT/bin/wave3-reset" 2>&1 >/dev/null)"; rc=$?; set -e
check "server down: reset fails with a clear message" '[ "$rc" -ne 0 ] && [[ "$err" == *"cannot reach the audio server"* ]]'

# --- levels: mic absent, headphone sink present ---
fresh no
echo "$CARD" > "$STUB/card"
echo "$SINK" > "$STUB/sink"
echo "output:analog-stereo" > "$STUB/profile"
out="$("$ROOT/bin/wave3-reset" --status)"
expected="$(cat <<EOF
present=no
default=no
muted=no
state=absent
profile=output:analog-stereo
volume=
sink=$SINK
sink_volume=45
sink_muted=no
EOF
)"
check "sink only: status shape" '[ "$out" = "$expected" ]'

fresh yes
echo 40 > "$STUB/sink_volume"
echo 51 > "$STUB/sink_volume_r"
out="$("$ROOT/bin/wave3-reset" --status)"
check "unequal channels: sink_volume rounds 40/51 to 46" 'printf "%s\n" "$out" | grep -qx "sink_volume=46"'

# --- meter ---
fresh yes
set +e; out="$("$ROOT/bin/wave3-meter" 2>"$TMP/meter.err")"; rc=$?; set -e
check "meter: peaks are 0, 32767, 32767" '[ "$out" = "$(printf "0\n32767\n32767")" ]'
check "meter: parec ending exits 1" '[ "$rc" -eq 1 ]'
log="$(cat "$STUB/parec.log")"
check "meter: parec targets the mic by name" '[[ "$log" == *"-d $SRC"* && "$log" == *"Wave:3 level meter"* && "$log" != *".monitor"* ]]'

fresh no
echo "$CARD" > "$STUB/card"
check "meter: monitor source is still listed" 'pactl list short sources | grep -q "\.monitor"'
set +e; err="$("$ROOT/bin/wave3-meter" 2>&1 >/dev/null)"; rc=$?; set -e
check "meter: missing mic exits 1" '[ "$rc" -eq 1 ] && [[ "$err" == "wave3-meter: Elgato Wave:3 input source not found" ]]'
check "meter: missing mic never starts parec" '[ ! -e "$STUB/parec.log" ]'

fresh yes; touch "$STUB/down"
set +e; err="$("$ROOT/bin/wave3-meter" 2>&1 >/dev/null)"; rc=$?; set -e
check "meter: server down exits 1" '[ "$rc" -eq 1 ] && [[ "$err" == "wave3-meter: cannot reach the audio server (pactl failed)" ]]'
check "meter: server down never starts parec" '[ ! -e "$STUB/parec.log" ]'

set +e; err="$("$ROOT/bin/wave3-meter" --bogus 2>&1 >/dev/null)"; rc=$?; set -e
check "meter: unknown option exits 2" '[ "$rc" -eq 2 ] && [[ "$err" == "wave3-meter: unknown option: --bogus" ]]'

fresh yes; touch "$STUB/parec-forever"
"$ROOT/bin/wave3-meter" >/dev/null 2>"$TMP/meter.err" &
mpid=$!
started=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if pgrep -f "$TMP/bin/parec" >/dev/null; then started=1; break; fi
  sleep 0.05
done
check "meter: forever mode starts parec" '[ "$started" -eq 1 ]'
kill -TERM "$mpid"
set +e
exited=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$mpid" 2>/dev/null; then exited=1; break; fi
  sleep 0.1
done
if [ "$exited" -eq 1 ]; then
  wait "$mpid"
  rc=$?
else
  kill -KILL "$mpid" 2>/dev/null || true
  wait "$mpid" 2>/dev/null || true
  rc=99
fi
set -e
check "meter: TERM exits 0" '[ "$rc" -eq 0 ]'
gone=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! pgrep -f "$TMP/bin/parec" >/dev/null; then gone=1; break; fi
  sleep 0.1
done
check "meter: TERM stops parec within 1s" '[ "$gone" -eq 1 ]'

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
