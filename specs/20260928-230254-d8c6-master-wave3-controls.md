# Spec: Wave:3 controls popup

Run `20260928-230254-d8c6-master`, branch `orch/20260928-230254-d8c6-master/sup-1`, base commit `07e48a2`.

## Problem

The bar widget (`Widget.qml`) only reports status. Clicking `BarIconButton` calls `root.reset()` (`Widget.qml:84`), which runs `bin/wave3-reset`. The widget reads nothing except the six `key=value` lines from `wave3-reset --status` (`bin/wave3-reset:67-90`, parsed by `Model.parseStatus` in `Model.js:9-33`). The user asked for controls over the Elgato Wave:3 (`0fd9:0070`) parameters. Today the plugin has no way to change input gain, mute, headphone (monitor) output level or mute, or to watch the input level, short of `pavucontrol`/`wpctl`. There is also no written record of which Wave Link features Linux can reach at all.

## Findings (live system, read-only, 2026-09-28)

Every command below was read-only. Nothing was changed on the device or in the audio server. The metering probe (F7) opened a capture stream for about 1.2 s.

### F1. ALSA card
- `arecord -l` / `aplay -l`: `card 0: Wave3 [Elgato Wave:3], device 0: USB Audio`, one capture and one playback device. The ALSA card id is `Wave3`. The card number (0 here) is not stable and must not be used.
- `/proc/asound/Wave3/stream0`: playback S24_3LE 2ch, capture S24_3LE 1ch (MONO), 48000/96000 Hz. The USB link is full speed.
- `amixer -c Wave3 contents` shows 4 mixer controls (plus two read-only channel maps):
  | numid | name | type | range | current |
  |---|---|---|---|---|
  | 5 | `Mic Capture Switch` | BOOLEAN rw | on/off | on |
  | 6 | `Mic Capture Volume` | INTEGER rw | 0–80, 0.00 dB → +40.00 dB | 80 (+40 dB) |
  | 3 | `PCM Playback Switch` | BOOLEAN rw | on/off | on |
  | 4 | `PCM Playback Volume` | INTEGER rw | 0–120, −60.00 dB → 0.00 dB | 79 (−20.50 dB) |
- There are no other controls: nothing for low-cut, Clipguard, mic/PC mix or LED.

### F2. Kernel
- `journalctl -k | grep -iE "wave|0fd9|GET_CUR"`: device enumerates as `usb 1-3: Product: Elgato Wave:3` and logs exactly one quirk line: `usb 1-3: 6:0: broken mixer GET_CUR (0/10240/128 => 2560)`. The kernel logs this when a feature unit returns an out-of-range value during init. Unit 6's 0–10240 (1/256 dB) range is the 0–40 dB capture range. The kernel clamps it, and the control still works, as F3 shows.

### F3. PipeWire / Pulse (`pactl`, PipeWire 1.6.8, pulse protocol 35)
- Card: `alsa_card.usb-Elgato_Systems_Elgato_Wave_3_<serial>-00`, matched today by `CARD_PATTERN='^alsa_card[.]usb-Elgato_Systems_Elgato_Wave_3'` (`bin/wave3-reset:14`).
- Profiles: `off`, `output:analog-stereo+input:mono-fallback` (active, 6501), `output:analog-stereo`, `output:iec958-stereo+input:mono-fallback`, `output:iec958-stereo`, `pro-audio`, `input:mono-fallback`.
- Source (mic): `alsa_input.usb-Elgato_Systems_Elgato_Wave_3_<serial>-00.mono-fallback`, description `Elgato Wave 3 Mono`, flags `HARDWARE HW_MUTE_CTRL HW_VOLUME_CTRL DECIBEL_VOLUME`, `Volume: mono: 65536 / 100% / 0.00 dB`, **`Base Volume: 14119 / 22% / -40.00 dB`**, `Mute: no`, port `analog-input-mic`. PipeWire drives the ALSA `Mic Capture Volume`/`Switch` directly. 100% is the hardware maximum (+40 dB analog gain), and 22% is 0 dB hardware gain. It is currently the default source.
- Sink (headphone jack on the mic): `alsa_output.usb-Elgato_Systems_Elgato_Wave_3_<serial>-00.analog-stereo`, description `Elgato Wave 3 Analog Stereo`, flags `HARDWARE HW_MUTE_CTRL HW_VOLUME_CTRL DECIBEL_VOLUME`, `front-left/right: 29491 / 45% / -20.81 dB`, `Base Volume 100%`, `Mute: no`, port `analog-output`. This matches ALSA `PCM Playback Volume` 79 (−20.5 dB). It is currently the default sink. The sink name pattern is `^alsa_output[.]usb-Elgato_Systems_Elgato_Wave_3`, and the node rule in `wireplumber/51-elgato-wave3.conf:37` already matches it. The sink carries the analog profile's playback from the PC. The Wave:3's own mic→headphone direct monitoring is mixed in hardware (see F5).
- The sink's monitor source is `...analog-stereo.monitor`. A source-name pattern must not match it. `SOURCE_PATTERN` (`^alsa_input[.]...`) already excludes it.
- Read commands that work by **name**: `pactl get-source-volume <name>`, `pactl get-source-mute <name>`, `pactl get-sink-volume <name>`, `pactl get-sink-mute <name>`, `pactl get-default-source`, `pactl get-default-sink`. The matching setters are `pactl set-source-volume|set-source-mute|set-sink-volume|set-sink-mute|set-default-source|set-default-sink <name> …` (not exercised; they are the documented pactl commands `wave3-reset` already uses for default and mute).
- `wpctl status`: `* 97. Elgato Wave 3 Mono [vol: 1.00]` under Sources, `* 53. Elgato Wave 3 Analog Stereo [vol: 0.45]` under Sinks, device `45. Elgato Wave:3`. `wpctl` addresses nodes by numeric id or `@DEFAULT_AUDIO_SOURCE@`/`@DEFAULT_AUDIO_SINK@` only. That breaks the "match by name, never numeric id" rule when the Wave:3 is not the default. **Controls therefore use `pactl` by name.** `wpctl` stays a verification tool (README "Verification").
- The source has `priority.session = 3000`, `session.suspend-timeout-seconds = 0` and `node.pause-on-idle = false`, all from the plugin's WirePlumber rule. `systemctl --user is-active wave3-watch` reports `active`.

### F4. Software DSP building blocks installed
- PipeWire filter-chain: `/usr/lib/pipewire-0.3/libpipewire-module-filter-chain.so`, graph plugins in `/usr/lib/spa-0.2/filter-graph/` (`builtin`, `ladspa`, `lv2`, `ebur128`, `sofa`). Built-in labels include `bq_highpass`, `bq_lowshelf`, `bq_peaking`, `noisegate`, `dcblock` and `clamp` (hard clip). There is **no built-in limiter**.
- LADSPA (`/usr/lib/ladspa`): `lsp-plugins-ladspa.so` (lsp-plugins 1.2.35) provides `limiter_mono`, `compressor_mono`, `gate_mono`, `filter_mono` and `para_equalizer_x8_mono`. `libdeep_filter_ladspa.so` (libdeep_filter_ladspa-bin 0.5.6) provides `deep_filter_mono` (DeepFilterNet noise suppression).
- LV2 (`/usr/lib/lv2`): `lsp-plugins.lv2`, `calf.lv2`.
- rnnoise: the `rnnoise` 0.2 package ships only `librnnoise.so`. **`librnnoise_ladspa` is not installed**, so `/usr/share/pipewire/filter-chain/source-rnnoise.conf` cannot run as shipped.
- `easyeffects` 8.2.9 is installed (not running). It already offers high-pass, limiter and DeepFilterNet/RNNoise noise reduction on any source, with a GUI.
- `~/.config/pipewire` does not exist, so no user filter-chain is configured.

### F5. Hardware-only Wave Link features
Clipguard, the hardware low-cut filter, the mic/PC monitor mix and the LED ring are set through Elgato's undocumented vendor protocol. ALSA exposes none of them (F1). They are out of reach by rule: no raw USB transfers, no reverse engineering.

### F6. Lint baseline (why `qmllint Widget.qml` exits 255)
- `/usr/bin/qmllint` is Qt 5 (`pacman -Qo`: `qt5-declarative 5.15.19`, `qmllint 1.0`). Its parser rejects a JavaScript function with a `void` return annotation and **prints nothing** (exit 255). This repo's IpcHandler declares `function reset(): void` and `function refresh(): void` (`Widget.qml:34-35`). Reproduced in isolation: `Item { function c(): void { } }` → exit 255, while `function a(x: string): string { … }` → exit 0. The camera repo exits 0 because its IpcHandler has no `: void` annotations (`abduldotdev.camera/Widget.qml:431-449`). Removing the two annotations from a scratch copy makes Qt 5 `qmllint` exit 0.
- Qt 6 lint: `/usr/lib/qt6/bin/qmllint` 6.11.2 exits 0 on `Widget.qml`, with 8 `Warning:` lines, all of them unresolved `qs.Ui` import/type warnings (`BarWidget`, `BarIconButton`, `anchors`, the `onExited` parameter type). `-I /usr/share/omarchy/shell` does not resolve `qs.Ui`.
- **Lint command for this run:** `/usr/lib/qt6/bin/qmllint <file>.qml`, run from the repo root. Baseline: `Widget.qml` exits 0 with 8 warnings. A new file has no baseline, so every warning it reports must be an unresolved-`qs.*`/Quickshell-import warning of the same kind. Qt 5 `qmllint` is not a valid check for this repo while `: void` annotations exist. If the implementation removes them, Qt 5 `qmllint` exiting 0 is a bonus check, not a requirement.
- `omarchy plugin validate "$PWD"` exits 0 on the base commit. `node --test tests/` passes 5/5 and `bash tests/scripts.test.sh` prints `all script tests passed`.

### F7. Level metering is possible with installed tools
`timeout 1.2 parec --raw --format=s16le --channels=1 --rate=8000 --latency-msec=100 -d <wave3 source name> | od -An -v -td2 -w1600 | awk '{…max |sample|…}'` printed 11 peak values in 1.2 s (150…396 of 32767 in a quiet room). The chain uses `parec` (libpulse), `od` (coreutils) and `awk`. It needs no new dependency, only a capture stream on the source. `pw-record` is also available. `python3` exists but is not an assumed prerequisite (README "Prerequisites").

### F8. Camera popup conventions (`../../abduldotdev.camera`)
- The popup is its own file, `CameraPopup.qml`, a `PopupWindow` with `required property Item anchorItem`, `required property QtObject bar`, `property var owner` and `property bool open`. It is instantiated once inside `Widget.qml:759`. It is not lazy-loaded; it stays hidden via `visible: open || card.opacity > 0` (`CameraPopup.qml:168`).
- Open/close: `onOpenChanged` calls `bar.requestPopout(coordinatorKey)` / `bar.releasePopout(coordinatorKey)` (`:171-175`). `HyprlandFocusGrab { active: root.open; onCleared: root.close() }` dismisses the popup on an outside click (`:186-190`). An `anchor.onAnchoring` handler places the popup beside the bar for top/bottom/left/right positions, clamped by `Style.gapsOut` (`:192-235`).
- Styling: `import qs.Commons` + `qs.Ui`. Colours come from `Color.popups.background/border/text`, `Color.accent`, `Color.muted` and `Color.urgent`. Borders use `Border.localOrSurfaceSpec(...)`. The card is a `BorderSurface` with `radius: Style.cornerRadius`, `padding: Style.spacing.popupPadding` and a 130 ms opacity fade. Width is 380. Foreground falls back to `#1a1a1a` on light backgrounds.
- Controls: `PanelSlider` (with `onMoved` debounced 150 ms, then committed on `onReleased`; polling is paused while dragging), `ToggleSwitch` and `Button` (`bordered`, `foreground/background/accent`) from `qs.Ui`. These are wrapped in local `component` types (`CameraSlider`, `CameraToggle`).
- Widget side: `open()` / `close()` / `toggle()` functions, and IPC `open`, `close`, `toggle` plus getters and setters (`Widget.qml:431-449`). Left click toggles the popup and right click resets (`Widget.qml:750-757`). A 3 s `Timer` re-reads controls only while `popup.open && !isDragging` (`:723-728`). The expensive resource (camera preview) sits in a `Loader` that is active only while the popup is open **and** the user asked for it (`CameraPopup.qml:59-74`).
- `Process` usage: one `Process` per command, with command arrays built by pure `Model.js` functions and output parsed by `Model.js` functions in `StdioCollector.onStreamFinished`.
- `Model.js` is ES5 only (no `const`/`let`/arrows/template strings), because Quickshell's JS import cannot run them. It is dual-exported via `if (typeof module !== "undefined") module.exports = …`. Tests `require("../Model.js")` with real-output fixtures (`tests/model.test.js`).
- One difference to keep: the camera widget is a bare `Item` with a hand-drawn `Text` icon and a `MouseArea`. The wave3 widget uses `BarWidget` + `BarIconButton` (`onPressed(int button)`, from `/usr/share/omarchy/shell/Ui/WidgetButton.qml:32`). The wave3 widget keeps `BarIconButton`.

## Scope

### In scope
- A controls popup, opened by clicking the bar icon, that follows the camera popup conventions in F8.
- Hardware controls over `pactl`, every device matched by name pattern: input (mic) volume/gain, input mute, headphone output volume, headphone output mute, set the Wave:3 mic as default source.
- A live input level/peak readout while the popup is open.
- Live status in the popup (present, default, muted, state, profile), plus the existing reset action (`wave3-reset`).
- `bin/wave3-reset --status` extended with the volume/mute/sink fields the popup needs, backward compatible.
- IPC for the popup (`open`, `close`, `toggle`), keeping `reset` and `refresh`.
- A README capability table and control documentation.
- Tests for all new parsing, command-building and script logic against stubbed `pactl` (and stubbed `parec` if a meter helper is added).
- A manifest description/version update.

### Out of scope
- **Software DSP (filter-chain low-cut / limiter / noise suppression)** for this run. See Open question 1 for the reasons and what including it would take.
- Hardware Clipguard, hardware low-cut, mic/PC mix and LED (F5). Documented as unsupported only.
- Profile picker UI beyond the existing reset (the profile toggle is `wave3-reset`'s job). Showing the active profile is in scope; switching to arbitrary profiles is not.
- Setting the Wave:3 headphone output as the default **sink** (not requested; see Open question 4).
- 96 kHz / sample-rate selection, pro-audio profile.
- Any change to `wireplumber/51-elgato-wave3.conf`, `bin/wave3-watch`, `systemd/`, `../link.sh` or `~/.config`.
- Changing the ALSA mixer directly with `amixer` (PipeWire already drives those controls; writing both would fight WirePlumber's route restore).

## Behaviour

Terms: **mic** means the first source whose name matches `^alsa_input[.]usb-Elgato_Systems_Elgato_Wave_3`. **Headphone out** means the first sink whose name matches `^alsa_output[.]usb-Elgato_Systems_Elgato_Wave_3`. **Card** is as in `bin/wave3-reset:14`. Numeric ids and serials are never used or stored.

### Bar icon
1. The bar icon keeps its current look: glyph `󰍭` when the mic is muted and `󰍬` otherwise, dimmed when absent, and `active` (warning colour) when present but not default or muted, or when the last action errored (`Widget.qml:76-85`, `Model.statusLevel`).
2. **Left click** toggles the popup. It no longer runs a reset.
3. **Right click** runs `wave3-reset` (the old left-click action, same as the camera's right-click reset). While it runs, the tooltip says `Resetting Wave:3…`. On failure the tooltip shows the last stderr line for 6 s, as today.
4. The tooltip summary (`Model.statusSummary`) ends with `— click for controls, right-click to reset` instead of `— click to reset`. The absent text stays `Wave:3 not connected`.
5. The bar icon's own 10 s status poll continues whether or not the popup is open.

### Popup: layout and lifecycle
6. The popup is a `PopupWindow` in its own QML file. It is anchored and styled exactly as in F8 (`requestPopout`/`releasePopout`, `HyprlandFocusGrab` outside-click dismiss, per-bar-position anchoring, `BorderSurface` card, `Color.popups.*`, `Style.*`, fade). It uses only `qs.Ui` components that exist in `/usr/share/omarchy/shell/Ui` (`PanelSlider`, `ToggleSwitch`, `Button`, `BorderSurface`).
7. Opening the popup triggers an immediate status read. While it is open, status is re-read every ≤ 3 s, and not while a slider is being dragged.
8. The popup shows these sections, top to bottom:
   - **Header**: `Elgato Wave:3` with a state line: `Not connected`, or `<state lower-case> · default input` / `not the default input` · `<profile description or name>`.
   - **Microphone**: gain slider, mute toggle, level meter, `Set as default` button.
   - **Headphones** (only when headphone out exists): volume slider, mute toggle.
   - **Actions**: `Reset` button (runs `wave3-reset`, disabled while running, shows its error line on failure).
   - **Unsupported note**: one line, `Clipguard, low-cut, mic/PC mix and LED need Elgato Wave Link — not available on Linux`. Wording may vary, but the popup must say these features are not available.
9. **Absent mic**: the header says `Not connected`. The Microphone and Headphones sections are hidden or disabled with a `Not connected` hint. Reset stays visible. The popup never errors or shows stale values from a previous connection.

### Popup: controls
10. **Mic gain slider.** 0–100 %, integer steps. It reflects `pactl get-source-volume <mic>` as a percentage (100 % = +40 dB hardware gain, F3). The value label shows `<n> %`, and the dB value too when known. While dragging, the label follows the thumb and a set command goes out at most every 150 ms. On release the final value is applied with `pactl set-source-volume <mic> <n>%`. Values above 100 % cannot be selected. If the mic is already above 100 % (set elsewhere), the slider shows 100 and the label shows the real value.
11. **Mic mute toggle.** Reflects `pactl get-source-mute <mic>`. Toggling runs `pactl set-source-mute <mic> 1|0`. The bar icon's glyph and colour follow within one status read (≤ 3 s while open).
12. **Set as default.** Visible and enabled only when the mic is present and not the default source. It runs `wave3-reset --default-only` (default + unmute, the existing behaviour), then re-reads status.
13. **Headphone volume slider.** 0–100 %, same drag/commit rules as B10, using `pactl get-sink-volume` / `pactl set-sink-volume <headphone out> <n>%`. Both channels are set to the same value. Unequal channels read back as the average.
14. **Headphone mute toggle.** Reflects/sets `pactl get-sink-mute` / `pactl set-sink-mute <headphone out> 1|0`.
15. **Failures.** If a set command exits non-zero (e.g. the device vanished mid-drag), the popup shows a short error line for 6 s and re-reads status. Nothing retries in a loop. Two set commands for the same control never run at once: the latest pending value wins.
16. **Name resolution.** Every set command targets the full source/sink name taken from the latest status read. If a name no longer matches the pattern or is gone, the command is not sent.

### Popup: level meter
17. While the popup is open **and** the mic is present, a meter shows the current input peak level, updated ≥ 8 times per second, plus a peak-hold marker that decays or resets after ≈ 1.5 s. It also shows a numeric peak readout in dBFS (e.g. `-23 dBFS`, `-∞` for silence). The meter measures post-gain signal, as recorded from the mic source.
18. The metering capture stream exists **only** while the popup is open and the mic is present. It stops within 1 s of the popup closing, the mic disappearing or the shell reloading. It never runs while the popup is closed. It must not change the default source, the volume, the mute state or the profile. If metering cannot start (tool missing or error), the meter shows `Level unavailable` and the other controls still work.
19. When the mic is muted, the meter shows silence (or a `Muted` label) rather than an error.

### `wave3-reset --status` (backward compatible)
20. It still prints the six existing keys (`present`, `default`, `muted`, `state`, `profile`, `source`) with unchanged meaning and still always exits 0. It also adds:
    - `volume=<integer percent>` of the mic (empty when absent);
    - `sink=<headphone out name>` (empty when absent);
    - `sink_volume=<integer percent>` (average of channels; empty when absent);
    - `sink_muted=yes|no` (`no` when absent).
    The existing tests in `tests/scripts.test.sh` keep passing unchanged, except that exact-output assertions may be widened to allow the new keys. `Model.parseStatus` returns the new fields with the defaults `volume: -1`, `sink: ""`, `sinkVolume: -1`, `sinkMuted: false`, and `-1` means unknown.
21. `--status` makes no set calls. The existing "changes nothing" checks cover this, and they must also cover the new keys.

### IPC
22. `omarchy-shell abduldotdev.wave3 open|close|toggle` control the popup. `reset` and `refresh` keep working as today. No other IPC is required.

## Affected surface

| file or module | change |
|---|---|
| `Widget.qml` | Left click toggles the popup, right click resets. Owns status, set commands, meter lifecycle and IPC `open/close/toggle`. Tooltip text via `Model`. |
| new `Wave3Popup.qml` (name indicative) | The `PopupWindow` described in B6–B19. |
| `Model.js` | ES5 only: parse the new status keys, build `pactl` set-command arrays by name, clamp/round percentages, parse meter output into peak/dBFS, updated `statusSummary`. |
| `bin/wave3-reset` | `--status` gains `volume`, `sink`, `sink_volume`, `sink_muted`. The rest is unchanged. |
| optional new `bin/wave3-meter` (or equivalent) | Only if metering needs a helper process. Prints one peak value per line from the mic, found by name. Uses installed tools only (F7). |
| `tests/model.test.js` | Tests for the new `Model.js` functions with fixtures from F3. |
| `tests/scripts.test.sh` | The stub `pactl` gains `get-source-volume`, `get-sink-volume`, `get-sink-mute` and `list short sinks`, with tests for B20/B21. A meter helper, if added, is tested with a stub `parec`. |
| `README.md` | Capability table, popup/controls/IPC docs, right-click reset, lint/test commands. |
| `manifest.json` | Description mentions controls, version `1.1.0`. |

## Acceptance criteria

1. **Popup opens from the bar icon.** Code inspection shows that `BarIconButton.onPressed` toggles the popup on the left button and runs `wave3-reset` on the right button. The popup file declares `PopupWindow` with `anchorItem`/`bar`/`owner`/`open`, calls `bar.requestPopout`/`releasePopout` in `onOpenChanged`, has a `HyprlandFocusGrab` bound to `open`, and uses `BorderSurface` + `Color.popups.*`. Manual check with the shell reloaded: a left click opens the popup, an outside click closes it, and `omarchy-shell abduldotdev.wave3 toggle` opens and closes it. The popup contains a working `Reset` button.
2. **Name-matched pactl controls.** `grep -nE "wpctl (set|get)|@DEFAULT_AUDIO" Widget.qml <popup>.qml Model.js bin/` returns nothing. Every set command in `Model.js`/QML is `pactl set-source-volume|set-source-mute|set-sink-volume|set-sink-mute` with a name argument, or `wave3-reset --default-only`. `node --test tests/` includes tests showing the command arrays for mic volume (clamped to 0–100, integer `%`), mic mute, sink volume and sink mute are built from the full names in a parsed status, and that no command is produced when the name is empty.
3. **Headphone section is conditional.** Model tests show `sink=` empty → headphone controls not available. A fixture with the real sink name from F3 → available.
4. **Level meter.** Code inspection shows the metering process runs only while `popup.open && status.present` (B18). Model tests parse sample meter output (including `0`, `32767` and a malformed line) into peak fraction and dBFS (`0` → `-∞`/silence, `32767` → ≈ `0 dBFS`). If a helper script is added, `bash tests/scripts.test.sh` runs it against a stub `parec` and checks that it targets the mic **by name** and never an `.monitor` source. Manual check: with the popup open, speaking moves the meter. After closing the popup, `pactl list short source-outputs` shows no stream from the plugin within 1 s.
5. **Status script.** `bash tests/scripts.test.sh` covers: present mic plus sink → `volume=`, `sink=<name>`, `sink_volume=`, `sink_muted=` lines. Absent → the absent shape including the empty/`no` new keys, exit 0. Server down → exit 0, absent shape. `--status` issues no `set-*` calls. All pre-existing checks still pass.
6. **README capability table.** `README.md` has a table with exactly these rows, each marked `supported-hardware`, `supported-software-equivalent` or `unsupported`, with a reason:
   | Feature | Expected mark | Reason to state |
   |---|---|---|
   | Gain | supported-hardware | ALSA `Mic Capture Volume` 0–40 dB via PipeWire source volume |
   | Mute | supported-hardware | ALSA `Mic Capture Switch` via source mute |
   | Monitor (headphone) level | supported-hardware | ALSA `PCM Playback Volume`/`Switch` via the sink. PC playback level only; the mic's direct-monitor mix is not reachable |
   | Clipguard | unsupported | vendor protocol only, not exposed by ALSA. Software limiter not shipped (see README note / EasyEffects) |
   | Low-cut | unsupported | vendor protocol only. Software high-pass not shipped |
   | Mic/PC mix | unsupported | vendor protocol only |
   | LED | unsupported | vendor protocol only |
   If Open question 1 is decided the other way, Clipguard and Low-cut become `supported-software-equivalent` and criterion 7 applies in full.
7. **Software DSP.** Default for this run (OQ1): no software DSP ships. `git grep -nE "filter-chain|bq_highpass|limiter_mono|deep_filter|module-ladspa" -- ':!specs' ':!README.md'` returns nothing, and the README may mention EasyEffects as the software route. If DSP is included anyway, it must be off by default, opt-in from the popup, fully reversible (turning it off leaves no loaded module, process or config file, and the raw Wave:3 source is again the default), limited to filters verified installed in F4, and it must not be undone by `wave3-watch` re-asserting the raw mic.
8. **Lint.** `/usr/lib/qt6/bin/qmllint Widget.qml` exits 0 with no new warning kinds beyond the 8-line baseline (F6). `/usr/lib/qt6/bin/qmllint <popup>.qml` exits 0, and each warning it prints is an unresolved `qs.*`/Quickshell import or type warning. `omarchy plugin validate "$PWD"` exits 0. The plan/report records the exact warning counts before and after.
9. **ES5 Model.js.** `grep -nE "\b(const|let)\b|=>|\`" Model.js` returns nothing.
10. **Tests.** `node --test tests/` and `bash tests/scripts.test.sh` both pass. The test run touches no real audio server: stubs are on `PATH`, and no test calls the real `pactl`/`parec`.
11. **Boundaries.** `git diff 07e48a2 --stat` shows no changes to `wireplumber/`, `bin/wave3-watch`, `systemd/`, `docs/link-sh-changes.md`, `../link.sh` or anything outside the repo.
12. **Committed.** `git status --porcelain` is empty after the final commit on `orch/20260928-230254-d8c6-master/sup-1`.

## Open questions

1. **Include software DSP (low-cut / Clipguard stand-in / noise suppression)?** The building blocks are installed: filter-chain built-in `bq_highpass`, LSP `limiter_mono` (LADSPA) and `deep_filter_mono` (LADSPA). The rnnoise LADSPA plugin is not. **Recommended default: do not include it in this run.** Reasons:
   (a) A filter-chain virtual source has a new name. `bin/wave3-watch` re-asserts the raw Wave:3 as default on every `new` source event (README "wave3-watch service"), so turning DSP on would be immediately undone unless the watcher and reset are changed too, which widens scope into `wave3-watch`.
   (b) Running it needs a long-lived `pipewire -c <conf>` child or a `pactl load-module` whose lifecycle must survive shell reloads and be cleaned up reliably.
   (c) EasyEffects 8.2.9 is already installed and does all three with a GUI.
   If included later, the design is: a single opt-in toggle, off by default, which starts one filter-chain virtual source (`bq_highpass` ~80 Hz → `limiter_mono`) and makes it the default while on. The watcher treats it as the Wave:3. Turning it off or unplugging removes it and restores the raw mic as default.
2. **Does the physical gain knob track the ALSA `Mic Capture Volume`?** It cannot be verified read-only (it needs someone turning the knob), and the kernel's `broken mixer GET_CUR` on unit 6 suggests the initial read is clamped. **Default:** treat the PipeWire source volume as the source of truth. The popup re-reads it every ≤ 3 s while open, so external changes show up. Note in the README that the knob and the software slider may disagree until the next read.
3. **Right-click = reset?** This changes today's left-click reset habit. **Default: yes**, matching the camera widget. The popup's Reset button and IPC `reset` stay available.
4. **Offer "set headphone out as default sink"?** The user did not ask for it. It is already the default sink on this machine. **Default: no.** Show the headphone controls only.
5. **Meter while muted and "mic in use" indicators.** A metering capture stream appears in `pactl list source-outputs` and may trip any shell "microphone in use" indicator while the popup is open. **Default:** accept this, because the stream is limited to the open popup (B18). The stream name should identify the plugin (e.g. `Wave:3 level meter`).
6. **Volume above 100 %.** PipeWire allows software boost above the +40 dB hardware maximum. **Default:** the slider caps at 100 % (hardware-only range, no digital clipping). Higher values set elsewhere are displayed, not reduced.
