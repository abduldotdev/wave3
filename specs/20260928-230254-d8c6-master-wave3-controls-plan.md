# Plan: Wave:3 controls popup
Spec: specs/20260928-230254-d8c6-master-wave3-controls.md

## Decisions (supervisor, on the spec's Open questions)
- OQ1: no software DSP this run. The README points to EasyEffects. The capability table has Clipguard and Low-cut as `unsupported`, and acceptance criterion 7 is the "nothing ships" grep.
- OQ2: PipeWire source volume is the source of truth. It is re-read every ≤ 3 s while the popup is open.
- OQ3: left click toggles the popup and right click runs `wave3-reset`.
- OQ4: no default-sink control.
- OQ5: the meter stream is accepted, and both its client and stream are named `Wave:3 level meter`.
- OQ6: sliders cap at 100 %. Higher values set elsewhere are shown as-is.

## Approach
The scripts stay the only code that talks to the audio server for reads. `wave3-reset --status` gains four keys, and a new `bin/wave3-meter` streams one peak value per line. The QML turns those lines into state through pure ES5 `Model.js` functions, and builds `pactl set-*` argv arrays by full name for writes. This keeps every piece of parsing testable in Node and every script testable against a stub `pactl`/`parec`, which is how the repo already tests (`tests/model.test.js`, `tests/scripts.test.sh`). The work splits along that seam into two streams with disjoint files. They share only the text contract below, so both can build against fixtures at the same time. Reading volumes from QML with separate `pactl get-*` Processes was rejected: it would duplicate the name matching `wave3-reset` already does and could not be tested without the shell.

## Interface contract (A produces, B consumes; both must match exactly)

### C1. `wave3-reset --status`
It prints ten `key=value` lines in this order and always exits 0. The first six are unchanged (`bin/wave3-reset:67-90`). The mic keys come from the mic source. The sink keys come from the first sink matching `^alsa_output[.]usb-Elgato_Systems_Elgato_Wave_3`, **independent of whether the mic is present**. Percentages are integers: the rounded mean of every `N%` token on the first line of `pactl get-source-volume` / `get-sink-volume`.

Present fixture (use verbatim in both test suites; the real names come from spec F3 with the serial replaced by `TEST123`):
```
present=yes
default=yes
muted=no
state=SUSPENDED
profile=output:analog-stereo+input:mono-fallback
source=alsa_input.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.mono-fallback
volume=100
sink=alsa_output.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.analog-stereo
sink_volume=45
sink_muted=no
```
Mic absent, sink present (e.g. `output:analog-stereo` profile):
```
present=no
default=no
muted=no
state=absent
profile=output:analog-stereo
volume=
sink=alsa_output.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.analog-stereo
sink_volume=45
sink_muted=no
```
Everything absent, or the server is down (`profile=` empty, no `source=` line, as today):
```
present=no
default=no
muted=no
state=absent
profile=
volume=
sink=
sink_volume=
sink_muted=no
```
`Model.parseStatus` maps `volume` → `volume` (int, `-1` when empty or not a number), `sink` → `sink` (string), `sink_volume` → `sinkVolume` (int, `-1`) and `sink_muted` → `sinkMuted` (`=== "yes"`). Unknown keys stay ignored.

### C2. `bin/wave3-meter`
- **CLI:** `wave3-meter` takes no arguments. Any argument → stderr `wave3-meter: unknown option: <arg>` and exit 2. `LC_ALL=C`.
- **Target:** the first line of `pactl list short sources` whose name (`$2`) matches `^alsa_input[.]usb-Elgato_Systems_Elgato_Wave_3` **and does not end in `.monitor`**. It never uses an id.
- **Capture:** `parec --raw --format=s16le --channels=1 --rate=8000 --latency-msec=100 --client-name="Wave:3 level meter" --stream-name="Wave:3 level meter" -d <name>`, piped through `od -An -v -td2 -w1600` and awk.
- **Output:** one line per 800-sample (100 ms) chunk, about 10 lines/s. Each line is a decimal integer `0`–`32767`, the peak `|sample|` of the chunk, with `-32768` clamped to `32767`. Each line ends in `\n` and is flushed immediately (awk `fflush()`). There is no other stdout output.
- **Exit:** mic not found → stderr `wave3-meter: Elgato Wave:3 input source not found`, exit 1, parec never started. pactl failing → stderr `wave3-meter: cannot reach the audio server (pactl failed)`, exit 1. parec ending on its own (source removed) → exit 1.
- **Stopping:** SIGTERM or SIGINT → it kills its own pipeline children and exits 0 within 1 s. If stdout closes, the pipeline dies of SIGPIPE on its next write. The QML stops it by setting `Process.running = false`.
- Test override: none needed. Tests put stub `pactl`/`parec` first on `PATH`.

### C3. Paths the QML uses
Both scripts are resolved like today's `resetScript` (`Widget.qml:10`), with `Qt.resolvedUrl("bin/wave3-meter")` for the meter. Stream B may reference `bin/wave3-meter` before Stream A lands it, and it only works after both are merged.

## Steps

### Stream A: scripts (worktree A)

1. **Status keys** — file(s): `bin/wave3-reset`
   - change: add `SINK_PATTERN='^alsa_output[.]usb-Elgato_Systems_Elgato_Wave_3'`, a `find_sink` built like `find_source` (reading `pactl list short sinks`), and a `percent` helper that averages the `N%` tokens on the first line of the input. `status()` prints C1's four new keys after the existing six in both branches. The absent branch still prints no `source=` line. A failing pactl yields empty values, and it still exits 0. Reset and `--default-only` behaviour stays unchanged.
   - verify: `bash tests/scripts.test.sh` (after step 2). The existing "changes nothing" checks stay green.
2. **Status tests** — file(s): `tests/scripts.test.sh`
   - change: the stub `pactl` gains `list short sinks` (prints the Wave:3 sink when `$STUB/sink` exists, plus the onboard `alsa_output.pci-0000_0d_00.4.analog-stereo`), `get-source-volume` (`Volume: mono: <v*655> / <v>% / 0.00 dB` from `$STUB/volume`), `get-sink-volume` (two channels from `$STUB/sink_volume`, unequal allowed via `$STUB/sink_volume_r`) and `get-sink-mute` (from `$STUB/sink_muted`). `fresh` writes defaults (`volume` 100, `sink_volume` 45, `sink_muted` no, the sink present iff the card is). New checks: the present output equals the C1 fixture line-for-line apart from `default`/`muted`, which `fresh` sets. Mic absent with sink present → the second C1 shape. Everything absent and server down → the third C1 shape, exit 0. Unequal channels 40/51 → `sink_volume=46`. `--status` makes no `set-*` calls.
   - verify: `bash tests/scripts.test.sh` prints `all script tests passed`.
3. **Meter helper** — file(s): `bin/wave3-meter` (new, `chmod +x`), `tests/scripts.test.sh`
   - change: implement C2. Stub `parec` logs its argv to `$STUB/parec.log` and writes 1600 zero bytes, then 1600 bytes of `0xff 0x7f` (32767) and then 1600 bytes of `0x00 0x80` (−32768). With `$STUB/parec-forever` it loops writing chunks with `sleep 0.05`. New checks:
     - Output is exactly `0\n32767\n32767`.
     - The parec argv contains `-d $SRC` and the `Wave:3 level meter` names, and never `.monitor`.
     - Mic absent (monitor source still listed) → exit 1, no parec call.
     - Server down → exit 1 with the C2 message.
     - Unknown arg → exit 2.
     - Forever mode plus `kill -TERM` → exit 0, and `pgrep -f "$TMP/bin/parec"` is empty within 1 s.
   - verify: `bash tests/scripts.test.sh`. `bash -n bin/wave3-meter`.

### Stream B: model and UI (worktree B)

4. **Model functions** — file(s): `Model.js`, `tests/model.test.js`
   - change (ES5 only, add to `module.exports`):
     - `parseStatus` gains the C1 fields.
     - `SOURCE_PATTERN`/`SINK_PATTERN` are RegExp literals matching the script patterns.
     - `clampPercent(v)` returns an integer in 0–100, or 0 for NaN.
     - `setSourceVolumeCommand(status, pct)`, `setSourceMuteCommand(status, muted)`, `setSinkVolumeCommand(status, pct)` and `setSinkMuteCommand(status, muted)` return `["pactl","set-source-volume",name,"<n>%"]` / `[…,"1"|"0"]`. They return `null` when the name is empty or fails its pattern, or when the source name ends in `.monitor`.
     - `headphonesAvailable(status)` is `present && sink !== ""`.
     - `canSetDefault(status)` is `present && !isDefault`.
     - `sliderValue(v)` is `v < 0 ? 0 : min(v, 100)`.
     - `volumeLabel(v)` returns `"<v> %"`, or `"—"` when `v` is `-1`.
     - `parseMeterLine(line)` returns `{ peak: n/32767, db: 20*log10(peak) or -Infinity }`, or `null` for non-integer or out-of-range lines.
     - `formatDb(db)` returns `"-∞ dBFS"` or `"<rounded> dBFS"`.
     - `holdPeak(hold, peak, now, holdMs)` returns `{ value, at }`. A higher peak replaces the held value. After `holdMs` (1500) the held value drops to the current peak.
     - `headerLine(status)` returns `Not connected` or `<state> · default input|not the default input · <profile>`.
     - `statusSummary`'s suffix becomes `— click for controls, right-click to reset`.
   - Tests use the three C1 fixtures and meter lines `0`, `32767`, `16384`, `abc`, `-5` and `40000`.
   - verify: `node --test tests/` all pass. `grep -nE "\b(const|let)\b|=>|\`" Model.js` returns nothing.
5. **Popup file** — file(s): `Wave3Popup.qml` (new)
   - change: a `PopupWindow` copying `CameraPopup.qml:10-235`'s shell: required `anchorItem`/`bar`, plus `owner`, `open`, `requestPopout`/`releasePopout`, `HyprlandFocusGrab`, the anchoring block, `BorderSurface` card, `Color.popups.*` colours, `Style.*` spacing and the 130 ms fade, at width 380. The popup owns no Processes. Its inputs are `status`, `level` (peak fraction), `holdLevel`, `levelText`, `meterAvailable`, `busy`, `errorText` and `resetting`. Its signals are `sourceVolumeRequested(int)`, `sourceMuteRequested(bool)`, `sinkVolumeRequested(int)`, `sinkMuteRequested(bool)`, `setDefaultRequested()` and `resetRequested()`, plus an `isDragging` property. The sections follow spec B8/B9:
     - Sliders: `PanelSlider` with `minimum` 0, `maximum` 100, `integer`, value `Model.sliderValue`. `onMoved` is debounced 150 ms, and `onReleased` commits, as in `CameraPopup.qml:283-363`.
     - Toggles: `ToggleSwitch`.
     - Buttons: `Button`.
     - Meter: a plain `Rectangle` bar plus a hold marker.
     - The unsupported-features line.
   - verify: `/usr/lib/qt6/bin/qmllint Wave3Popup.qml` exits 0, and every warning it prints is an unresolved `qs.*`/Quickshell import or type.
6. **Widget wiring** — file(s): `Widget.qml`
   - change:
     - `BarIconButton.onPressed(b)`: `b === Qt.RightButton` → `reset()`, otherwise `toggle()`.
     - Add `open()`/`close()`/`toggle()` and IPC `open`, `close`, `toggle` next to `reset`/`refresh`. Drop the `: void` annotations so that Qt 5 lint also passes. This is optional; see Risks.
     - Poll `Timer` of 3 s, running while `popup.open && !popup.isDragging`, calling `refresh()`. The existing 10 s timer stays.
     - `setProc`: one `Process` with a pending map keyed by control (`srcVol`, `srcMute`, `sinkVol`, `sinkMute`) where the latest value wins. It runs the next pending command on exit. A non-zero exit sets `errorText` for 6 s via `errorTimer` and calls `refresh()`. Commands come only from the `Model.set*Command` functions, and `null` is skipped.
     - `setDefaultRequested` runs `resetScript --default-only` through the reset path, then refreshes.
     - `meterProc`: `Process { command: [meterScript]; running: popup.open && root.status.present; stdout: SplitParser { onRead: … Model.parseMeterLine … Model.holdPeak … } }`. `onExited` with a non-zero code sets `meterAvailable = false` until the next open. Closing resets the levels to 0.
     - Opening calls `refresh()` immediately.
   - verify: `/usr/lib/qt6/bin/qmllint Widget.qml` exits 0 with no warning kinds beyond the 8-line baseline (spec F6). `grep -nE "wpctl (set|get)|@DEFAULT_AUDIO" Widget.qml Wave3Popup.qml Model.js` is empty.
7. **Docs and manifest** — file(s): `README.md`, `manifest.json`
   - change:
     - README Features: popup controls, left/right click, meter, IPC `open|close|toggle`, and the `--status` new keys. Also describe `bin/wave3-meter` (the file itself is Stream A's).
     - The capability table exactly as spec acceptance criterion 6, plus an EasyEffects note for the software high-pass, limiter and noise reduction.
     - A knob-vs-slider note (OQ2).
     - Testing and lint commands (`/usr/lib/qt6/bin/qmllint`).
     - The Files table lists `Wave3Popup.qml` and `bin/wave3-meter`.
     - `manifest.json`: version `1.1.0`, and the description and `barWidget.description` mention the controls.
   - verify: `omarchy plugin validate "$PWD"` exits 0. `git grep -nE "filter-chain|bq_highpass|limiter_mono|deep_filter|module-ladspa" -- ':!specs' ':!README.md'` is empty.

### Integration (supervisor, after both streams)

8. **Merge and full check** — file(s): none new
   - change: merge A and B. There are no overlapping files, so no conflicts are expected.
   - verify: every row of Checks. Then manually: reload the shell, left click opens the popup, an outside click closes it, `omarchy-shell abduldotdev.wave3 toggle` works, speaking moves the meter, and after closing `pactl list short source-outputs` shows no `Wave:3 level meter` stream within 1 s. Right click resets. `git diff 07e48a2 --stat` touches nothing in `wireplumber/`, `bin/wave3-watch`, `systemd/` or `docs/`. `git status --porcelain` is empty.

## Parallelisation
| step | owns files | may run concurrently with |
|---|---|---|
| 1 | `bin/wave3-reset` | 4–7 |
| 2 | `tests/scripts.test.sh` | 4–7 (sequential after 1 within stream A) |
| 3 | `bin/wave3-meter`, `tests/scripts.test.sh` | 4–7 (after 2 within stream A) |
| 4 | `Model.js`, `tests/model.test.js` | 1–3 |
| 5 | `Wave3Popup.qml` | 1–3 (after 4 within stream B) |
| 6 | `Widget.qml` | 1–3 (after 5 within stream B) |
| 7 | `README.md`, `manifest.json` | 1–3 (after 6 within stream B) |
| 8 | merge only | none |

Stream A = steps 1→2→3, one worker, one worktree. Stream B = steps 4→5→6→7, one worker, one worktree. The file sets are disjoint. C1–C3 are the only coupling.

## Checks
| command | when |
|---|---|
| `bash tests/scripts.test.sh` | end of steps 2, 3; step 8 |
| `bash -n bin/wave3-reset bin/wave3-meter` | end of steps 1, 3 |
| `node --test tests/` | end of step 4; step 8 |
| `grep -nE "\b(const\|let)\b\|=>\|\`" Model.js` (must be empty) | end of step 4; step 8 |
| `/usr/lib/qt6/bin/qmllint Wave3Popup.qml` | end of step 5; step 8 |
| `/usr/lib/qt6/bin/qmllint Widget.qml` (exit 0, baseline 8 warnings) | end of step 6; step 8 |
| `grep -nE "wpctl (set\|get)\|@DEFAULT_AUDIO" Widget.qml Wave3Popup.qml Model.js bin/` (empty) | end of step 6; step 8 |
| `omarchy plugin validate "$PWD"` | end of step 7; step 8 |
| `git grep -nE "filter-chain\|bq_highpass\|limiter_mono\|deep_filter\|module-ladspa" -- ':!specs' ':!README.md'` (empty) | step 8 |

## Risks
- **Orphaned `parec` after the shell kills the meter.** Assume Quickshell signals only the bash PID (unverified), not a process group. Without an explicit trap that kills the pipeline, `parec` lingers until its next write fails. Detection: the step 3 forever-mode `kill -TERM` + `pgrep` check, and the step 8 `source-outputs` check.
- **The stub `pactl` `list short` branch.** It treats every non-`cards` call as sources (`tests/scripts.test.sh`). Adding `sinks` without branching on `$3` would feed source lines to `find_sink`. Detection: the step 2 absent-mic-with-sink shape check.
- **`set -euo pipefail` in `--status`.** A failing `pactl get-sink-volume` must not abort status (it must always exit 0). Detection: the server-down check in step 2.
- **ES5 slips in `Model.js`.** Node runs arrows and `const`, but Quickshell does not, and `qmllint` does not read `Model.js`. Detection: the ES5 grep.
- **Qt 5 `qmllint`** keeps exiting 255 while `: void` annotations exist (spec F6). Dropping them in step 6 is harmless to IPC. Quickshell IpcHandler functions need typed params/returns only when they take or return values, so no-arg `void` functions work unannotated, as the camera's `open()`/`close()` do (`abduldotdev.camera/Widget.qml:434-436`). If the supervisor prefers the annotations, the Qt 6 check stands alone.
- **Slider feedback loop.** A 3 s poll while dragging would snap the thumb back. Detection: inspect that the poll timer is gated on `!popup.isDragging`, and that slider `value` is not written while `slider.dragging`.
- **The meter runs while the mic is suspended.** `session.suspend-timeout-seconds = 0` keeps the node awake anyway, so opening a stream cannot hit the stuck-suspend bug. If the meter stays at `0` with real sound, the Reset button is the remedy.
