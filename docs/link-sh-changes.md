# link.sh changes for abduldotdev.wave3

`link.sh` already links this plugin directory into `~/.config/omarchy/plugins/`
(it has a `manifest.json`). Add these lines after the antigravity block, before
the `--icon` handling. They reuse the existing `link` helper and the
`~/.local/bin` / `~/.config/systemd/user` directories `link.sh` already creates.

```bash
W="$REPO/abduldotdev.wave3"
mkdir -p "$HOME/.config/wireplumber/wireplumber.conf.d"
link "$W/wireplumber/51-elgato-wave3.conf" "$HOME/.config/wireplumber/wireplumber.conf.d/51-elgato-wave3.conf"
link "$W/bin/wave3-reset" "$HOME/.local/bin/wave3-reset"
link "$W/bin/wave3-watch" "$HOME/.local/bin/wave3-watch"
# Optional. The bar widget runs bin/wave3-hw from the plugin directory.
# Link it only if you want the command on PATH.
link "$W/bin/wave3-hw" "$HOME/.local/bin/wave3-hw"
link "$W/systemd/wave3-watch.service" "$HOME/.config/systemd/user/wave3-watch.service"
systemctl --user daemon-reload
systemctl --user enable --now wave3-watch.service
```

`link.sh` already runs `systemctl --user daemon-reload` for antigravity; if the
wave3 lines go after it, the second reload is harmless. Or drop it and move the
`enable --now` line below the existing reload.

## One-time steps at install (not in link.sh)

WirePlumber only reads the new rules when it starts, and the stored default
source is still the absent BOYALINK mic. Run these once after `link.sh`:

```bash
systemctl --user restart wireplumber
wave3-reset          # or: wpctl set-default <id of "Elgato Wave 3 Mono" from wpctl status>
```

These are left out of `link.sh` on purpose: restarting WirePlumber drops every
open audio stream, which is wrong for a script meant to be safe to re-run.

The udev rule is also manual, and it needs `sudo`, so it does not belong in
`link.sh` either. It only grants the logged-in seat user access to the USB
device node. Audio stays with `snd-usb-audio`.

```bash
sudo install -m644 "$REPO/abduldotdev.wave3/udev/70-elgato-wave3.rules" /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger
```
