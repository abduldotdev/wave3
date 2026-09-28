# abduldotdev.wave3

Keeps an **Elgato Wave:3** USB microphone (`0fd9:0070`) as the reliable, always-working default input on Omarchy, and drives the vendor features the PipeWire volume slider cannot reach (gain, mute, Clipguard, low cut, headphone level, monitor blend, LEDs, gain lock, dial mode). It remembers the hardware settings you choose and puts them back when the mic is plugged in again. It ships a WirePlumber rule, a reset script, a small watcher service, `bin/wave3-hw`, and a bar icon that shows the mic's state and opens a controls popup.

## Why

The Wave:3 is not dropping off USB. Two separate problems make it look that way:

1. **Wrong default.** WirePlumber's configured default source is a wireless BOYALINK mic that is usually absent. When it is missing, WirePlumber falls back by priority, and the Wave:3 (`priority.session` 2100) ranks below the MX Brio webcam mic (2109), which is muted. Apps then record silence.
2. **Stuck suspend.** The Wave:3 input node (`alsa_input.usb-Elgato_Systems_Elgato_Wave_3_*`) suspends after 5 s idle and sometimes does not wake up. Switching the card to a Digital (IEC958) profile and back to `output:analog-stereo+input:mono-fallback` reopens it.

This plugin fixes the first with priorities and a watcher, avoids the second by never suspending the node, and makes the profile toggle a single command for when it still happens.

## Features

- **WirePlumber rule**: pins the analog profile, raises the Wave:3 input to priority 3000 (above every other source), and disables idle suspend on its input and output. Everything is matched by name pattern, never by serial number or numeric id.
- **`wave3-reset`**: switches the card to the digital profile and back, waiting after each switch until the source reappears under a new index, then sets the Wave:3 as the default source and unmutes it. Safe to run repeatedly. Exits non-zero with a message on stderr when the mic is not plugged in.
  - `wave3-reset --default-only`: set default and unmute only, without touching the profile. This still forces the Wave:3 when a filter source is the default.
  - `wave3-reset --ensure-default`: like `--default-only`, but a no-op (exit 0, with a message) when the current default is virtual. `wave3-watch` uses this. Plain `wave3-reset` and `--default-only` still force the Wave:3.
  - `wave3-reset --status`: prints `present=`, `default=`, `default_virtual=`, `muted=`, `state=`, `profile=`, `source=` lines, then `volume=` (mic percent), `sink=` (headphone output name), `sink_volume=` and `sink_muted=`. `default_virtual=yes` when the current default exists in `pactl list short sources`, does not start with `alsa_input.` or `bluez_input.`, and does not end in `.monitor` (for example `easyeffects_source`). It is `no` for the Wave:3 itself, any other physical input, a monitor, or a default that is not listed. Always exits 0, and prints the absent shape when the mic or the audio server is missing. The sink keys are filled whenever the headphone output exists, even without the mic.
- **`wave3-hw`**: reads and writes the vendor control block over USB (API 5.3 or 5.4). Python 3, standard library only. The widget runs `bin/wave3-hw` from the plugin directory.
  - `wave3-hw status`: always exits 0. Prints `present=yes|no`, `access=ok|denied|` (empty when the device is absent), `device=`, `api=` (empty unless `access=ok`) and `supported=yes|no` (`yes` only for API 5.3 or 5.4). When `access=ok` it also prints `gain_db=`, `mute=`, `clipguard=`, `lowcut=`, `hp_db=`, `hp_mute=`, `direct_monitor=`, `volume_select=`, `leds_off=`, `leds_flip=`, `gain_lock=` and `raw=`. Decibel values use one decimal (`10.0`, `-20.5`); `direct_monitor` is an integer percent. It reads under the device lock. When the lock is still held after 2 s, or the USB node keeps answering `EBUSY`/`EAGAIN` (each USB operation is retried with backoff for about 1 s), the output is the single line `error=busy`. Any other unexpected error prints the single line `error=<one line>`. No field lines are printed before an `error=` line, and it still exits 0.
  - `wave3-hw set <field> <value>`: every field above except `raw`. Booleans accept `0`, `1`, `on`, `off`, `yes`, `no`, `true`, `false`. `volume_select` also accepts `mic`, `headphone`, `mix` (stored as 1, 2, 3). Numbers are clamped and rounded to the step: gain 0–40 dB by 0.5, headphones −60–0 dB by 0.5, monitor blend 0–100 by 5. Refuses to write unless the API version is 5.3 or 5.4. Reads the whole block, changes only the target bytes, writes it back and fails if the read-back differs. Concurrent calls take turns on a lock file. Success prints `<field>=<stored value>`, then one `saved=` line, and exits 0:
    - `saved=yes`: the value read back from the device was recorded in the settings store (see [Remembered settings](#remembered-settings)).
    - `saved=no`: the field is never stored (`mute`, `volume_select`).
    - `saved=error`: the device took the value but the store could not be written. stderr says `wave3-hw: could not save setting: <reason>`.

    A failed write leaves the store alone and prints no `saved=` line.
  - `wave3-hw apply [--settle SECONDS] [--retries N]`: writes the stored settings back to the device. It reads the block, re-encodes only the stored fields that differ, writes once and verifies the read-back. Nothing is written when everything already matches. With `--retries N` it then sleeps `SECONDS` (outside the lock) and checks again `N` times, fixing any drift each round. `--settle` is 0–30 (default 0), `--retries` 0–10 (default 0); `--flag value` and `--flag=value` both work. Output:

    ```
    store=ok|missing|corrupt
    changed=<fields written by the first attempt>
    reapplied=<fields written by later rounds>
    result=applied|noop|absent|denied|unsupported|mismatch|busy|error
    ```

    A missing store (or one with no usable fields) is `result=noop`, exit 0, and the device is not opened. The result and exit code come from the last round. Each failed round adds a `wave3-hw: apply attempt <i>: <reason>` line on stderr. `apply` never writes the store.
  - `wave3-hw save`: reads the device and replaces the store with its current values for every stored field. Prints one `<field>=<value>` line per field, then `saved=yes`.
  - `wave3-hw forget`: deletes the store. Prints `forgotten=yes`, or `forgotten=no` when there was none. It does not open the device, so it works with the mic unplugged.
  - Exit codes: `0` ok, `2` usage / bad field / bad value, `3` device absent, `4` permission denied (stderr names the udev command below), `5` unsupported API version, `6` read-back mismatch, `7` settings store corrupt (`apply` only), `8` device busy (lock wait over 2 s, or `EBUSY`/`EAGAIN` retries exhausted), `1` anything else. Every command, `status` and `forget` included, takes the same lock at `$XDG_RUNTIME_DIR/wave3-hw.lock`. The message is `wave3-hw: <text>` on stderr.
  - Tests set `WAVE3_HW_FAKE=<dir>` and never open a USB device. A missing directory means absent; `<dir>/denied` means permission denied; `<dir>/version` is the API text (`5.3` when the file is missing); `<dir>/config` is 16 hex bytes separated by spaces. `<dir>/readonly` drops writes so a read-back mismatch can be tested. `<dir>/busy` holds a count of operations that fail with `EBUSY`; `<dir>/drift` replaces `config` on the second read after the first write (a late OS volume write); each write appends a line to `<dir>/writes`. `device=` then prints `fake:<dir>`.
- **Level meter**: native PipeWire peak monitor (`PwNodePeakMonitor`) tracking the Wave:3 input node directly. While the popup is open and the mic is present, the meter adds a Quickshell peak-monitor stream on the Wave:3 input (visible in `pactl list source-outputs`, may light a mic-in-use indicator), stopping when the popup closes or is hidden. It provides a smooth per-quantum (~47 Hz) dBFS level meter with a 1.5 s peak hold.
- **`wave3-watch` service**: listens to `pactl subscribe` and runs `wave3-reset --ensure-default` once at start and whenever a source or card is added. It only reacts to `new` events, so the `change` events from setting the default never retrigger it.
  - At the same moments it runs `wave3-hw apply --settle 2.5 --retries 2` in the background, from its own directory (or `$WAVE3_HW`). That is an immediate apply plus checks at about +2.5 s and +5 s, which put the settings back if the ALSA/WirePlumber volume restore lands after the card appears. After the last check, later OS volume changes are left alone.
  - A new apply is skipped while one is still running, or within `WAVE3_APPLY_INTERVAL` seconds (default 5, `0` turns off only this window) of the previous one's start. Skipped events are dropped, not queued; the running apply's later checks cover the burst of events one replug produces.
  - Each apply logs one journal line when it finishes, for example `wave3-watch: apply rc=0 store=ok changed=gain_db,lowcut,gain_lock reapplied= result=applied`. `wave3-hw`'s own stderr goes to the journal too. A failed or missing `wave3-hw` never stops the watcher or the default-source reset.
  - EasyEffects and other filter sources are chosen on purpose, so the watcher leaves the default alone when it is virtual (`easyeffects_source`, or any listed source that is not `alsa_input.*`, `bluez_input.*` or a `.monitor`). It re-asserts the Wave:3 when the default is missing or not in the source list (the absent BOYALINK), when it is a physical input such as the MX Brio, or when it is a `.monitor`. To choose another physical mic yourself, stop the watcher for this session with `systemctl --user stop wave3-watch`, or turn it off for good with `systemctl --user disable --now wave3-watch`. Right-click reset still runs plain `wave3-reset` and forces the raw Wave:3.
- **Bar widget**: a microphone icon, dimmed when the Wave:3 is absent and in the warning colour when it is not the default or is muted. A filter source (`default_virtual=yes`) is not that warning. The tooltip shows the state. Left click opens the controls popup, right click runs `wave3-reset`. `wave3-reset --status` is polled every 10 s; with the popup closed, `wave3-hw status` runs at most every 30 s.
- **Controls popup**: shows the state line (connected, default input, profile). When `default_virtual=yes` the state line says the default is a filter source (for example EasyEffects). Hardware mode is `wave3-hw status` reporting `present=yes`, `access=ok` and `supported=yes`. The sections then are:
  - **MICROPHONE**: hardware gain, 0–40 dB in 0.5 dB steps, with a large dB readout and −/+ buttons, plus mute (hardware `mute`) and the live peak meter in dBFS with a 1.5 s peak hold.
  - **MONITORING**: headphone level in dB, −60–0 (hardware `hp_db`), with mute (`hp_mute`); monitor blend, Mic ↔ Computer (`direct_monitor`, 0 is all mic and 100 is all computer).
  - **ONBOARD PROCESSING**: Clipguard and Low cut toggles.
  - **DEVICE**: Gain lock, with a one-line note that while it is on the OS and apps cannot change the gain (the knob and this panel still can); LEDs off, flip LEDs, and dial mode (`volume_select`: mic, headphone, mix).

  Without hardware access the popup shows `Hardware controls need setup:` and the udev install command, then the existing pactl mute and headphone controls as a fallback. There is no gain slider in that case. The bar icon, right-click reset, IPC and the meter (only while the popup is open and the mic is present) stay as they are. Hardware writes go through one process at a time. Sliders send at most one change every 150 ms while dragging, keep the latest value per field, and apply the final value on release. A failed write shows its stderr line briefly and status is read again. After a write that was recorded (`saved=yes`) the popup shows `Saved · restores on reconnect` for 4 s; `saved=error` shows `Changed, but could not save it for reconnect`. Status is re-read every 3 s while the popup is open, but not while you drag a slider, and hardware status is never read while a write is queued or running. An `error=busy` (or other `error=`) read keeps the last good hardware state on screen instead of dropping to the setup view; only `present=no`, `access=denied`, `supported=no` or a good read changes the mode.
- **IPC**: `omarchy-shell abduldotdev.wave3 open|close|toggle` for the popup, `reset` and `refresh` as before.

## Wave Link features on Linux

| Feature | Mark | Reason |
|---|---|---|
| Gain | supported-hardware | Vendor control protocol, `gain_db` 0–40 dB in 0.5 steps |
| Mute | supported-hardware | Vendor control protocol, `mute` |
| Headphone level | supported-hardware | Vendor control protocol, `hp_db` −60–0 dB and `hp_mute` |
| Clipguard | supported-hardware | Vendor control protocol, `clipguard` |
| Low cut | supported-hardware | Vendor control protocol, `lowcut` |
| Mic/PC mix (monitor blend) | supported-hardware | Vendor control protocol, `direct_monitor` (0 = all mic, 100 = all computer) |
| LEDs | supported-hardware | Vendor control protocol, `leds_off` and `leds_flip` |
| Gain lock | supported-hardware | Vendor control protocol, `gain_lock` |
| Dial mode | supported-hardware | Vendor control protocol, `volume_select` (mic / headphone / mix) |

`wave3-hw` speaks the protocol documented by [elgato-wave3-ubuntu](https://github.com/KailasMahavarkar/elgato-wave3-ubuntu) (MIT). Capture and playback stay on `snd-usb-audio`; the tool only opens the USB device node to read and write the control block.

**Gain lock:** while gain lock is on, the firmware ignores OS volume changes, which is why the old popup slider (PipeWire source volume) did nothing to the real gain. The knob and `wave3-hw set gain_db` still change it. Turn gain lock off when an app should control the level. The level meter measures the recorded signal, after gain.

While the popup is open, the meter adds a Quickshell peak-monitor stream on the Wave:3 input (visible in `pactl list source-outputs`, may light a mic-in-use indicator), stopping when the popup closes or is hidden.

## Remembered settings

The Wave:3 keeps its settings in volatile memory, and Wave Link is what puts them back on Windows and macOS. After a replug or reboot the mic comes up with its own defaults (for example gain 40 dB, low cut and gain lock off). This plugin keeps your choices in a store and restores them.

- **Store:** `$XDG_STATE_HOME/abduldotdev.wave3/hw.json`, which is `~/.local/state/abduldotdev.wave3/hw.json` when `XDG_STATE_HOME` is unset. `WAVE3_HW_STORE=<path>` overrides it. The directory is created `0700` and the file written `0600`, through a temporary file and a rename, so it is never half-written.
- **What is recorded:** every successful `wave3-hw set` (and so every hardware change in the popup) of `gain_db`, `clipguard`, `lowcut`, `hp_db`, `hp_mute`, `direct_monitor`, `leds_off`, `leds_flip` or `gain_lock`. Only fields you have set are stored. `wave3-hw save` stores the device's current values for all of them at once; `wave3-hw forget` deletes the store. Nothing records the device state on its own, so power-on defaults never overwrite your choices.
- **When it is restored:** `wave3-watch` runs `wave3-hw apply` when it starts and when the mic reappears (see the watcher bullet above). With `gain_lock` stored as on, the first write sets the lock together with the gain, so the OS volume restore is ignored by the firmware.
- **Mute is not restored.** A mic that comes back muted after a reboot or replug is easy to miss in a call, so hardware `mute` is never stored (`set mute` prints `saved=no`).
- **Dial mode (`volume_select`) is not restored.** The device changes it on its own (it was seen going from headphone to mic with no write), so a restored value would not stay and would fight the knob. `set volume_select` prints `saved=no`, and `apply` never writes it.
- **Corrupt store:** `apply` prints `store=corrupt` and exits 7 without touching the device. The next `set` or `save` replaces it with a fresh store and says so on stderr; `forget` removes it. A single invalid value is skipped with a `wave3-hw: store: ignoring <field>` line while the rest apply.

## EasyEffects

Pick the Wave:3 as EasyEffects' input, then select `easyeffects_source` as the default source. `wave3-watch` treats that name as a virtual source and leaves it alone. If Clipguard or Low cut is on in hardware, turn EasyEffects' limiter or high-pass off so the signal is not processed twice. Right-click reset (and `wave3-reset` / `--default-only`) still forces the raw Wave:3, past the filter. Other EasyEffects plugins, such as noise reduction, can stay on.

## Files

| Path | Installed to | Purpose |
|---|---|---|
| `manifest.json`, `Widget.qml`, `Model.js` | `~/.config/omarchy/plugins/abduldotdev.wave3` | Bar widget; `Model.js` parses `--status`, `wave3-hw status` and pactl commands |
| `Wave3Popup.qml` | `~/.config/omarchy/plugins/abduldotdev.wave3` | Controls popup |
| `wireplumber/51-elgato-wave3.conf` | `~/.config/wireplumber/wireplumber.conf.d/` | Profile, priority and suspend rules |
| `bin/wave3-reset` | `~/.local/bin/` | Reset / default / status script |
| `bin/wave3-watch` | `~/.local/bin/` | Event watcher run by the service |
| `bin/wave3-hw` | plugin directory; optional `~/.local/bin/` | Vendor control CLI (`status` / `set` / `apply` / `save` / `forget`) |
| `udev/70-elgato-wave3.rules` | `/etc/udev/rules.d/` (manual, sudo) | Seat-user access to the USB device node |
| `systemd/wave3-watch.service` | `~/.config/systemd/user/` | Runs the watcher for the user session |
| (created at runtime) | `~/.local/state/abduldotdev.wave3/hw.json` | Remembered hardware settings, written by `wave3-hw set` / `save` |

The scripts find their siblings through `readlink -f`, so they work when symlinked. The widget runs the plugin's own `bin/wave3-reset` and `bin/wave3-hw` and does not need the `~/.local/bin` links.

## Prerequisites

`pactl` (from `libpulse`), `awk`, `python3` (for `wave3-hw`), and WirePlumber 0.5, all present on Omarchy by default. Nothing else is installed.

## Installation

This plugin lives in the omarchy-plugins repo and is installed by its `link.sh`, which links every plugin directory into `~/.config/omarchy/plugins/`. The config, scripts and unit need these extra lines in `link.sh` (also in [docs/link-sh-changes.md](docs/link-sh-changes.md)):

```bash
W="$REPO/abduldotdev.wave3"
mkdir -p "$HOME/.config/wireplumber/wireplumber.conf.d"
link "$W/wireplumber/51-elgato-wave3.conf" "$HOME/.config/wireplumber/wireplumber.conf.d/51-elgato-wave3.conf"
link "$W/bin/wave3-reset" "$HOME/.local/bin/wave3-reset"
link "$W/bin/wave3-watch" "$HOME/.local/bin/wave3-watch"
# Optional. The widget runs the copy in the plugin directory.
link "$W/bin/wave3-hw" "$HOME/.local/bin/wave3-hw"
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

## Hardware access (udev)

`wave3-hw` needs to open the USB device node. This is not part of `link.sh`: it needs `sudo`, and it is the only step that does. The rule tags the device `uaccess` for the logged-in seat user. It does not detach `snd-usb-audio` or claim an interface, so capture and playback stay with the kernel driver.

Plugin path: `$REPO/abduldotdev.wave3` or `~/…/abduldotdev.wave3`.

```bash
sudo install -m644 "$REPO/abduldotdev.wave3/udev/70-elgato-wave3.rules" /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger
```

The popup shows the same command when hardware access is missing. After it is installed, `wave3-hw status` should show `access=ok`. Permission denied names this command. Remove it with:

```bash
sudo rm -f /etc/udev/rules.d/70-elgato-wave3.rules && sudo udevadm control --reload && sudo udevadm trigger
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
- **Settings reset after replug**: check the watcher is running (`systemctl --user status wave3-watch`) and that `journalctl --user -u wave3-watch` shows a `wave3-watch: apply rc=0 ... result=applied` (or `result=noop`) line after the replug. `store=missing` means nothing was ever recorded: set the values in the popup, or run `wave3-hw save`. `result=denied` means the udev rule is missing. `store=corrupt` means `hw.json` is unreadable; run `wave3-hw save` to replace it. Mute and dial mode are never restored.
- **Profile is not analog after replug**: WirePlumber prefers the profile stored in `~/.local/state/wireplumber/default-profile` over `device.profile`. `wave3-reset` ends on the analog profile, which WirePlumber then stores as the user choice.

## Uninstall

```bash
systemctl --user disable --now wave3-watch.service
rm ~/.config/systemd/user/wave3-watch.service ~/.local/bin/wave3-reset ~/.local/bin/wave3-watch
rm -f ~/.local/bin/wave3-hw   # only if the optional link was installed
rm ~/.config/wireplumber/wireplumber.conf.d/51-elgato-wave3.conf
rm ~/.config/omarchy/plugins/abduldotdev.wave3
systemctl --user daemon-reload
systemctl --user restart wireplumber
```

Also remove the wave3 lines from `link.sh`, or it will recreate the links. The only state the plugin writes is the settings store; remove it with `rm -rf ~/.local/state/abduldotdev.wave3`. The default source it set stays in WirePlumber's normal state file until you pick another one.

## Testing

The node and shell suites use fixtures or a stub `pactl` on `PATH` and never touch the real audio server. The Python suite uses `WAVE3_HW_FAKE` and never opens a USB device, and sets `WAVE3_HW_STORE` to a temporary file so it never touches your settings store:

```bash
node --test tests/          # Model.js parsing and pactl command building
bash tests/scripts.test.sh  # wave3-reset and wave3-watch against stubs
python3 -m unittest discover -s tests -p 'test_*.py'  # wave3-hw
```

`tests/live-hw.sh` is the live check, run after the udev rule is installed. For each of `clipguard`, `lowcut`, `gain_lock`, `direct_monitor` and `gain_db` it writes the current value, changes it, reads it back and restores the original. The same script runs against `WAVE3_HW_FAKE`. When `WAVE3_HW_STORE` is unset it points it at a temporary file for the run, so the test values are not recorded as your settings.

Lint the QML with Qt 6 `qmllint` (the Qt 5 `/usr/bin/qmllint` rejects the `: void` IPC annotations). Warnings about unresolved `qs.*` and Quickshell imports are expected, because those modules only exist inside the shell:

```bash
/usr/lib/qt6/bin/qmllint Widget.qml
/usr/lib/qt6/bin/qmllint Wave3Popup.qml
omarchy plugin validate "$PWD"
```

## License

MIT License. See [LICENSE](LICENSE) for details.
