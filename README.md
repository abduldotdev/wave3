# abduldotdev.wave3

Keeps an **Elgato Wave:3** USB microphone (`0fd9:0070`) as the reliable, always-working default input on Omarchy. It ships a WirePlumber rule, a reset script, a small watcher service, and a bar icon that shows the mic's state and opens a controls popup for gain, mute, headphone volume and a live input level meter.

## Why

The Wave:3 is not dropping off USB. Two separate problems make it look that way:

1. **Wrong default.** WirePlumber's configured default source is a wireless BOYALINK mic that is usually absent. When it is missing, WirePlumber falls back by priority, and the Wave:3 (`priority.session` 2100) ranks below the MX Brio webcam mic (2109), which is muted. Apps then record silence.
2. **Stuck suspend.** The Wave:3 input node (`alsa_input.usb-Elgato_Systems_Elgato_Wave_3_*`) suspends after 5 s idle and sometimes does not wake up. Switching the card to a Digital (IEC958) profile and back to `output:analog-stereo+input:mono-fallback` reopens it.

This plugin fixes the first with priorities and a watcher, avoids the second by never suspending the node, and makes the profile toggle a single command for when it still happens.

## Features

- **WirePlumber rule**: pins the analog profile, raises the Wave:3 input to priority 3000 (above every other source), and disables idle suspend on its input and output. Everything is matched by name pattern, never by serial number or numeric id.
- **`wave3-reset`**: switches the card to the digital profile and back, waiting after each switch until the source reappears under a new index, then sets the Wave:3 as the default source and unmutes it. Safe to run repeatedly. Exits non-zero with a message on stderr when the mic is not plugged in.
  - `wave3-reset --default-only`: set default and unmute only, without touching the profile.
  - `wave3-reset --status`: prints `present=`, `default=`, `muted=`, `state=`, `profile=`, `source=` lines, then `volume=` (mic percent), `sink=` (headphone output name), `sink_volume=` and `sink_muted=`. Always exits 0, and prints the absent shape when the mic or the audio server is missing. The sink keys are filled whenever the headphone output exists, even without the mic.
- **`wave3-meter`**: prints the mic's peak level (`0`–`32767`) once per 100 ms from a `parec` capture stream named `Wave:3 level meter`. It finds the mic by name and never records a `.monitor` source. The widget runs it only while the popup is open and the mic is present.
- **`wave3-watch` service**: listens to `pactl subscribe` and runs `wave3-reset --default-only` once at start and whenever a source or card is added. It only reacts to `new` events, so the `change` events from setting the default never retrigger it.
  - **This re-asserts the Wave:3 as the default whenever *any* source appears**, not only the Wave:3. Plugging in a headset or starting a virtual source moves the default back to the Wave:3 if it is connected. To choose another mic yourself, stop the watcher for this session with `systemctl --user stop wave3-watch`, or turn it off for good with `systemctl --user disable --now wave3-watch`.
- **Bar widget**: a microphone icon, dimmed when the Wave:3 is absent and in the warning colour when it is not the default or is muted. The tooltip shows the state. Left click opens the controls popup, right click runs `wave3-reset`. Status is polled every 10 s.
- **Controls popup**: shows the state line (connected, default input, profile) and has:
  - **Microphone**: a gain slider (0–100 %, where 100 % is the +40 dB hardware maximum), a mute toggle, a live peak meter in dBFS with a 1.5 s peak hold, and a `Set as default` button when another mic is the default.
  - **Headphones** (when the mic's headphone output exists): a volume slider and a mute toggle.
  - A `Reset` button, which runs `wave3-reset`.

  Every change is a `pactl set-source-volume|set-source-mute|set-sink-volume|set-sink-mute` call on the full device name from the last status read, so nothing is sent when the Wave:3 is gone. Sliders send at most one change every 150 ms while dragging and apply the final value on release. Values above 100 % set elsewhere are shown but cannot be picked. Status is re-read every 3 s while the popup is open, but not while you drag a slider.
- **IPC**: `omarchy-shell abduldotdev.wave3 open|close|toggle` for the popup, `reset` and `refresh` as before.

## Wave Link features on Linux

| Feature | Mark | Reason |
|---|---|---|
| Gain | supported-hardware | ALSA `Mic Capture Volume` 0–40 dB via PipeWire source volume |
| Mute | supported-hardware | ALSA `Mic Capture Switch` via source mute |
| Monitor (headphone) level | supported-hardware | ALSA `PCM Playback Volume`/`Switch` via the sink. PC playback level only; the mic's direct-monitor mix is not reachable |
| Clipguard | unsupported | Vendor protocol only, not exposed by ALSA. Software limiter not shipped (see EasyEffects below) |
| Low-cut | unsupported | Vendor protocol only. Software high-pass not shipped |
| Mic/PC mix | unsupported | Vendor protocol only |
| LED | unsupported | Vendor protocol only |

Elgato sets Clipguard, low-cut, the mic/PC mix and the LED through an undocumented protocol that Linux does not expose, and this plugin does not reverse-engineer it. For a software high-pass, limiter or noise reduction, use [EasyEffects](https://github.com/wwmm/easyeffects) on the Wave:3 input. It is packaged for Arch and does all three.

**Gain knob:** the popup treats the PipeWire source volume as the truth. The physical knob and the slider may disagree until the next status read (3 s while the popup is open). The level meter measures the recorded signal, after gain.

While the popup is open the meter's capture stream shows in `pactl list source-outputs` as `Wave:3 level meter`, and it may light a "microphone in use" indicator. It stops within a second of closing the popup.

## Files

| Path | Installed to | Purpose |
|---|---|---|
| `manifest.json`, `Widget.qml`, `Model.js` | `~/.config/omarchy/plugins/abduldotdev.wave3` | Bar widget; `Model.js` parses `--status` and meter output and builds the `pactl` commands |
| `Wave3Popup.qml` | `~/.config/omarchy/plugins/abduldotdev.wave3` | Controls popup |
| `wireplumber/51-elgato-wave3.conf` | `~/.config/wireplumber/wireplumber.conf.d/` | Profile, priority and suspend rules |
| `bin/wave3-reset` | `~/.local/bin/` | Reset / default / status script |
| `bin/wave3-watch` | `~/.local/bin/` | Event watcher run by the service |
| `bin/wave3-meter` | plugin directory only | Level meter the popup runs |
| `systemd/wave3-watch.service` | `~/.config/systemd/user/` | Runs the watcher for the user session |

The scripts find their siblings through `readlink -f`, so they work when symlinked. The widget runs the plugin's own `bin/wave3-reset` and `bin/wave3-meter` and does not need the `~/.local/bin` links.

## Prerequisites

`pactl` and `parec` (from `libpulse`), `od` and `awk`, and WirePlumber 0.5, all present on Omarchy by default. Nothing else is installed.

## Installation

This plugin lives in the omarchy-plugins repo and is installed by its `link.sh`, which links every plugin directory into `~/.config/omarchy/plugins/`. The config, scripts and unit need these extra lines in `link.sh` (also in [docs/link-sh-changes.md](docs/link-sh-changes.md)):

```bash
W="$REPO/abduldotdev.wave3"
mkdir -p "$HOME/.config/wireplumber/wireplumber.conf.d"
link "$W/wireplumber/51-elgato-wave3.conf" "$HOME/.config/wireplumber/wireplumber.conf.d/51-elgato-wave3.conf"
link "$W/bin/wave3-reset" "$HOME/.local/bin/wave3-reset"
link "$W/bin/wave3-watch" "$HOME/.local/bin/wave3-watch"
link "$W/systemd/wave3-watch.service" "$HOME/.config/systemd/user/wave3-watch.service"
systemctl --user daemon-reload
systemctl --user enable --now wave3-watch.service
```

Then, once:

```bash
./link.sh
systemctl --user restart wireplumber   # load the new rules (drops open audio streams)
wave3-reset                            # make the Wave:3 the default now
```

## Verification

```bash
# The Wave:3 Mono source is marked * (default) under Audio > Sources
wpctl status

# priority.session / priority.driver = 3000, session.suspend-timeout-seconds = 0
wpctl inspect <id of "Elgato Wave 3 Mono">

# What the widget sees
wave3-reset --status

# Watcher is running
systemctl --user status wave3-watch

# Watch WirePlumber while replugging the mic
journalctl --user -u wireplumber -f
```

The config syntax can be checked without touching the running daemon:

```bash
spa-json-dump wireplumber/51-elgato-wave3.conf
```

WirePlumber has no dry-run mode. After the restart, `journalctl --user -u wireplumber` shows any rule it could not parse.

## Troubleshooting

- **Mic records silence**: run `wave3-reset` (or right-click the bar icon). It reopens the input with the profile toggle.
- **Default keeps going back to another mic**: check `wpctl inspect` shows priority 3000 on the Wave:3 input. If not, the conf is not linked or WirePlumber was not restarted.
- **Profile is not analog after replug**: WirePlumber prefers the profile stored in `~/.local/state/wireplumber/default-profile` over `device.profile`. `wave3-reset` ends on the analog profile, which WirePlumber then stores as the user choice.

## Uninstall

```bash
systemctl --user disable --now wave3-watch.service
rm ~/.config/systemd/user/wave3-watch.service ~/.local/bin/wave3-reset ~/.local/bin/wave3-watch
rm ~/.config/wireplumber/wireplumber.conf.d/51-elgato-wave3.conf
rm ~/.config/omarchy/plugins/abduldotdev.wave3
systemctl --user daemon-reload
systemctl --user restart wireplumber
```

Also remove the wave3 lines from `link.sh`, or it will recreate the links. The plugin writes no state of its own. The default source it set stays in WirePlumber's normal state file until you pick another one.

## Testing

Both suites use fixtures or a stub `pactl`/`parec` on `PATH` and never touch the real audio server:

```bash
node --test tests/          # Model.js parsing and pactl command building
bash tests/scripts.test.sh  # wave3-reset, wave3-watch and wave3-meter against stubs
```

Lint the QML with Qt 6 `qmllint` (the Qt 5 `/usr/bin/qmllint` rejects the `: void` IPC annotations). Warnings about unresolved `qs.*` and Quickshell imports are expected, because those modules only exist inside the shell:

```bash
/usr/lib/qt6/bin/qmllint Widget.qml
/usr/lib/qt6/bin/qmllint Wave3Popup.qml
omarchy plugin validate "$PWD"
```

## License

MIT License. See [LICENSE](LICENSE) for details.
