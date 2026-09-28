# Wave:3 hardware controls and EasyEffects coexistence — spec and plan

Run `20260929-000605-22d6-master`, workstream sup-1. This file is the shared
contract between the three implementation streams. Change it only by asking
the supervisor.

## Background

A read-only probe on the real mic (API 5.3) returned the /config block
`00 0a 00 ec 00 01 01 80 eb 00 00 00 01 00 00 01`, which decodes to gain 10 dB,
mute 0, Clipguard 1, Low cut 1, headphones -20.5 dB, hp mute 0, direct monitor
0 %, dial 1 (MIC), LEDs off 0, flip 0, gain lock 1. With gain lock on, the
firmware ignores OS SET_CUR, so the popup's current Gain slider (pactl source
volume) does not change real gain. It must be replaced by the hardware gain.

Protocol (MIT, credit it): https://github.com/KailasMahavarkar/elgato-wave3-ubuntu
(`research/dump/PROTOCOL.md`, `wave3/protocol.py`). Transport reused from the
run's `wave3-probe.py`: `USBDEVFS_CONTROL` ioctl on `/dev/bus/usb/BBB/DDD`,
found by scanning `/sys/bus/usb/devices/*` for `idVendor=0fd9 idProduct=0070`.

- Read: bmRequestType `0xA1`, bRequest `0x85`, wIndex `0x3303`.
- Write: bmRequestType `0x21`, bRequest `0x05`, same wValue/wIndex, full block.
- `/version`: wValue `0x000A`, 2 bytes `[major, minor]`.
- `/config`: wValue `0x0000`, 16 bytes.

| byte | field (CLI name) | encoding | range / step |
|---|---|---|---|
| 0-1 | `gain_db` | int16 LE Q8.8 dB | 0..40, 0.5 |
| 2-3 | reserved | preserve verbatim (live `00 ec`) | — |
| 4 | `mute` | 0/1 | — |
| 5 | `clipguard` | 0/1 | — |
| 6 | `lowcut` | 0/1 | — |
| 7-8 | `hp_db` | int16 LE Q8.8 dB | -60..0, 0.5 |
| 9 | `hp_mute` | 0/1 | — |
| 10-11 | `direct_monitor` | int16 LE Q8.8 percent (0 = all mic, 100 = all computer) | 0..100, 5 |
| 12 | `volume_select` (dial mode) | 1 MIC, 2 HEADPHONE, 3 MIX | 1..3 |
| 13 | `leds_off` | 0/1 | — |
| 14 | `leds_flip` | 0/1 | — |
| 15 | `gain_lock` | 0/1 | — |

## Contract A — `bin/wave3-hw` (python3, stdlib only)

### `wave3-hw status`

Always exits 0. Prints `key=value` lines in this order:

```
present=yes|no
access=ok|denied|      (empty when present=no)
device=/dev/bus/usb/001/003   (empty when absent)
api=5.3                (empty unless access=ok)
supported=yes|no       (yes only for api 5.3 or 5.4)
gain_db=10.0
mute=0
clipguard=1
lowcut=1
hp_db=-20.5
hp_mute=0
direct_monitor=0
volume_select=1
leds_off=0
leds_flip=0
gain_lock=1
raw=00 0a 00 ec 00 01 01 80 eb 00 00 00 01 00 00 01
```

The field lines and `raw=` are printed only when `access=ok`. dB values print
with one decimal (`10.0`, `-20.5`); `direct_monitor` prints an integer percent.
An unexpected error prints `error=<one line>` and still exits 0.

### `wave3-hw set <field> <value>`

- Fields: every CLI name in the table except reserved.
- Booleans accept `0 1 on off yes no true false`. `volume_select` also accepts
  `mic headphone mix`. Numbers are clamped to the range and rounded to the step.
- Refuses to write unless `/version` is 5.3 or 5.4.
- Reads the whole block, changes only the target bytes, writes the whole block,
  reads back, and fails if the target bytes differ from what was written. All
  other bytes (including reserved 2-3) are preserved exactly.
- Serialised with `fcntl.flock` on `${XDG_RUNTIME_DIR:-/tmp}/wave3-hw.lock`, so
  concurrent invocations run one at a time.
- On success prints `<field>=<value as stored>` and exits 0.
- Exit codes: 0 ok, 2 usage / bad field / bad value, 3 device absent,
  4 permission denied, 5 unsupported API version, 6 read-back mismatch,
  1 anything else. The message goes to stderr as `wave3-hw: <text>`, and
  permission denied names the udev install command (below).

### Fake transport (tests only, never touches USB)

`WAVE3_HW_FAKE=<dir>` replaces the USB transport:

- dir missing → device absent.
- `<dir>/denied` exists → permission denied.
- `<dir>/version` text `5.3` (default `5.3` if the file is missing).
- `<dir>/config` text: 16 hex bytes separated by spaces. Writes rewrite it in
  the same format.
- `<dir>/readonly` exists → writes are silently dropped (for read-back tests).
- `device=` prints `fake:<dir>`.

### udev

`udev/70-elgato-wave3.rules`:

```
SUBSYSTEM=="usb", ATTR{idVendor}=="0fd9", ATTR{idProduct}=="0070", TAG+="uaccess"
```

Grants the logged-in seat user access to the USB device node only. The audio
interfaces stay with `snd-usb-audio`: nothing detaches kernel drivers or
claims interfaces. Install command (shown in the popup and README; `<plugin>`
is the plugin directory):

```
sudo install -m644 <plugin>/udev/70-elgato-wave3.rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger
```

## Contract B — `wave3-reset --status` addition and wave3-watch

`wave3-reset --status` gains one line after `default=`:

```
default_virtual=yes|no
```

`yes` when the current default source exists and is a virtual or filter source
(for example `easyeffects_source`, or any source whose name does not start with
`alsa_input.` or `bluez_input.`, and is not a `.monitor`). `no` otherwise,
including when the Wave:3 itself is the default.

`wave3-watch` leaves the default alone when it is virtual. It re-asserts the
Wave:3 only when the default is missing/empty/not in the source list (e.g. the
absent BOYALINK), or is a physical non-Wave input, or a `.monitor`. The manual
`wave3-reset` / `--default-only` (right-click) still force the Wave:3.

## Contract C — widget and popup

The widget runs `bin/wave3-hw status` alongside `wave3-reset --status` on every
status read. Hardware mode = `present=yes`, `access=ok`, `supported=yes`.

Popup sections, modelled on the Wave XLR MK.2 panel:

- **MICROPHONE**: hardware Gain slider 0–40 dB (0.5 steps) with a big dB
  readout and −/+ step buttons; Mute mic (hardware `mute`); the level meter.
- **MONITORING**: Headphones slider in dB (−60..0, hardware `hp_db`) with mute
  (`hp_mute`); Monitor blend slider Mic ↔ Computer (`direct_monitor`).
- **ONBOARD PROCESSING**: Clipguard and Low cut toggles.
- **DEVICE**: Gain lock toggle with a one-line explanation (when on, the OS and
  apps cannot change the gain; the knob and this panel still can); optional
  LEDs off, Flip LEDs, dial mode.

Without hardware access: a clear line “Hardware controls need setup:” with the
exact install command above, and the existing pactl mute + headphone controls
as fallback. No gain slider is shown in that case (never a fake gain). The bar
icon, right-click reset, IPC, and the meter gating (`Model.meterRunning` with
`popup.visible`) stay as they are. When `default_virtual=yes`, the icon is not
in the warning state for “not default” and the state line says the default is
a filter source (e.g. EasyEffects).

Hardware writes go through one `Process` at a time; slider changes are
debounced and latest-wins per field (same pattern as the existing
`queueSet`/`pendingSets`). A failed write shows its stderr line briefly and
triggers a status re-read.

## Streams

| stream | owns |
|---|---|
| hw | `bin/wave3-hw`, `tests/test_wave3_hw.py`, `udev/70-elgato-wave3.rules`, `tests/live-hw.sh` |
| ui | `Model.js`, `Widget.qml`, `Wave3Popup.qml`, `tests/model.test.js`, `manifest.json` |
| watch+docs | `bin/wave3-watch`, `bin/wave3-reset`, `tests/scripts.test.sh`, `README.md`, `docs/link-sh-changes.md` |

`tests/live-hw.sh` is run later by a human/orchestrator after the udev rule is
installed. For each of `clipguard`, `lowcut`, `gain_lock`, `direct_monitor`,
`gain_db`: set the current value (no-op), change it, read back, restore the
original, read back. On the first mismatch it restores every field it changed
and exits non-zero. Prints a table. It must work against `WAVE3_HW_FAKE` too.

## Checks

```
node --test tests/
bash tests/scripts.test.sh
python3 -m unittest discover -s tests -p 'test_*.py'
/usr/lib/qt6/bin/qmllint Widget.qml Wave3Popup.qml   # no new warning kinds
```

Baseline qmllint kinds: Widget.qml `import, signal-handler-parameters,
unqualified, unresolved-type`; Wave3Popup.qml `import, missing-type,
unqualified, unresolved-type`.
