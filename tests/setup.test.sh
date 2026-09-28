#!/bin/bash
# Exercises bin/wave3-setup and wave3-watch keep_default behavior.
# Uses temporary HOME, XDG_CONFIG_HOME, stub systemctl, and stub udev dirs.
# NEVER touches the real user HOME or system configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolated HOME and XDG_CONFIG_HOME
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/home/.config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

# Stub systemctl
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$SYSTEMCTL_LOG"
case "$*" in
  *"--user is-enabled wave3-watch.service"*)
    if [ -f "$SYSTEMCTL_STATE/enabled" ]; then
      echo "enabled"
      exit 0
    else
      echo "disabled"
      exit 1
    fi ;;
  *"--user is-active wave3-watch.service"*)
    if [ -f "$SYSTEMCTL_STATE/active" ]; then
      echo "active"
      exit 0
    else
      echo "inactive"
      exit 3
    fi ;;
  *"--user daemon-reload"*)
    [ -f "$SYSTEMCTL_STATE/fail-reload" ] && { echo "Failed to reload daemon" >&2; exit 1; }
    exit 0 ;;
  *"--user enable --now wave3-watch.service"*)
    [ -f "$SYSTEMCTL_STATE/fail-enable" ] && { echo "Failed to enable service" >&2; exit 1; }
    touch "$SYSTEMCTL_STATE/enabled" "$SYSTEMCTL_STATE/active"
    exit 0 ;;
  *"--user disable --now wave3-watch.service"*)
    rm -f "$SYSTEMCTL_STATE/enabled" "$SYSTEMCTL_STATE/active"
    exit 0 ;;
  *)
    echo "unexpected systemctl call: $*" >&2
    exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/systemctl"

export WAVE3_SYSTEMCTL="$TMP/bin/systemctl"
export SYSTEMCTL_LOG="$TMP/systemctl.log"
export SYSTEMCTL_STATE="$TMP/systemctl-state"
mkdir -p "$SYSTEMCTL_STATE"
: > "$SYSTEMCTL_LOG"

# Stub udev dirs
UDEV_DIR="$TMP/udev/rules.d"
mkdir -p "$UDEV_DIR"
export WAVE3_UDEV_RULES_DIRS="$UDEV_DIR"

fails=0
pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi }

SETUP="$ROOT/bin/wave3-setup"
WATCH="$ROOT/bin/wave3-watch"

WP_CONF="$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/51-elgato-wave3.conf"
SVC_FILE="$XDG_CONFIG_HOME/systemd/user/wave3-watch.service"

# --- 1. Unknown command / no command usage ---
set +e
err1="$("$SETUP" 2>&1 >/dev/null)"
rc1=$?
err2="$("$SETUP" invalid-cmd 2>&1 >/dev/null)"
rc2=$?
set -e
check "usage: no args exits 2" '[ "$rc1" -eq 2 ] && [[ "$err1" == *"Usage:"* ]]'
check "usage: invalid arg exits 2" '[ "$rc2" -eq 2 ] && [[ "$err2" == *"Usage:"* ]]'

# --- 2. Clean status shape ---
out="$("$SETUP" status)"
expected="$(cat <<EOF
wireplumber=missing
service=missing
service_enabled=no
service_active=no
udev=missing
keep_default=yes
setup=none
plugin_dir=$ROOT
udev_command=sudo install -m644 '$ROOT/udev/70-elgato-wave3.rules' /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger
EOF
)"
check "status: clean initial state matches exact shape" '[ "$out" = "$expected" ]'

# --- 3. Status partial states ---
mkdir -p "$(dirname "$WP_CONF")"
ln -s "$ROOT/wireplumber/51-elgato-wave3.conf" "$WP_CONF"
out="$("$SETUP" status)"
check "status: wireplumber installed only gives setup=partial" 'printf "%s\n" "$out" | grep -qx "wireplumber=installed" && printf "%s\n" "$out" | grep -qx "setup=partial"'

# Also link unit file and enable
mkdir -p "$(dirname "$SVC_FILE")"
cat > "$SVC_FILE" <<EOF
# Managed by abduldotdev.wave3 wave3-setup
[Unit]
Description=Test
EOF
touch "$SYSTEMCTL_STATE/enabled"
out="$("$SETUP" status)"
check "status: wireplumber and enabled service without udev gives setup=partial" 'printf "%s\n" "$out" | grep -qx "service=installed" && printf "%s\n" "$out" | grep -qx "service_enabled=yes" && printf "%s\n" "$out" | grep -qx "udev=missing" && printf "%s\n" "$out" | grep -qx "setup=partial"'

# With udev installed, setup is complete
touch "$UDEV_DIR/70-elgato-wave3.rules"
out="$("$SETUP" status)"
check "status: all installed gives setup=complete" 'printf "%s\n" "$out" | grep -qx "setup=complete"'

# Reset temporary test state
rm -f "$WP_CONF" "$SVC_FILE" "$UDEV_DIR/70-elgato-wave3.rules"
rm -f "$SYSTEMCTL_STATE/enabled" "$SYSTEMCTL_STATE/active"

# --- 4. Install from scratch ---
: > "$SYSTEMCTL_LOG"
set +e
out="$("$SETUP" install 2>"$TMP/install.err")"
rc=$?
set -e
check "install: exits 0 on clean install" '[ "$rc" -eq 0 ] && [ ! -s "$TMP/install.err" ]'
check "install: creates wireplumber symlink" '[ -L "$WP_CONF" ] && [ "$(readlink -f "$WP_CONF")" = "$ROOT/wireplumber/51-elgato-wave3.conf" ]'
check "install: creates service unit with marker" '[ -f "$SVC_FILE" ] && grep -qF "# Managed by abduldotdev.wave3 wave3-setup" "$SVC_FILE"'
check "install: unit contains ConditionPathExists" 'grep -qx "ConditionPathExists=$ROOT/bin/wave3-watch" "$SVC_FILE"'
check "install: unit contains ExecStart" 'grep -q -E "^ExecStart=\"?$ROOT/bin/wave3-watch\"?" "$SVC_FILE"'
check "install: calls systemctl daemon-reload and enable --now" 'grep -qx "systemctl --user daemon-reload" "$SYSTEMCTL_LOG" && grep -qx "systemctl --user enable --now wave3-watch.service" "$SYSTEMCTL_LOG"'
check "install: prints linked, wrote, and notes" '[[ "$out" == *"linked: $WP_CONF"* && "$out" == *"wrote: $SVC_FILE"* && "$out" == *"Note: WirePlumber"* && "$out" == *"Hardware controls need one sudo step:"* ]]'
check "install: does not write keep-default config" '[ ! -f "$XDG_CONFIG_HOME/abduldotdev.wave3/config" ]'

# --- 5. Idempotent re-install ---
: > "$SYSTEMCTL_LOG"
set +e
out="$("$SETUP" install 2>"$TMP/install.err")"
rc=$?
set -e
check "install idempotent: exits 0" '[ "$rc" -eq 0 ] && [ ! -s "$TMP/install.err" ]'
check "install idempotent: reports already installed" '[[ "$out" == *"ok: $WP_CONF already installed"* && "$out" == *"ok: $SVC_FILE already installed"* ]]'
check "install idempotent: still runs daemon-reload and enable" 'grep -qx "systemctl --user daemon-reload" "$SYSTEMCTL_LOG" && grep -qx "systemctl --user enable --now wave3-watch.service" "$SYSTEMCTL_LOG"'

# --- 6. Uninstall reverses owned files ---
: > "$SYSTEMCTL_LOG"
set +e
out="$("$SETUP" uninstall 2>"$TMP/uninstall.err")"
rc=$?
set -e
check "uninstall: exits 0" '[ "$rc" -eq 0 ] && [ ! -s "$TMP/uninstall.err" ]'
check "uninstall: removes wireplumber symlink" '[ ! -e "$WP_CONF" ] && [ ! -L "$WP_CONF" ]'
check "uninstall: removes service unit" '[ ! -e "$SVC_FILE" ] && [ ! -L "$SVC_FILE" ]'
check "uninstall: calls systemctl disable --now and daemon-reload" 'grep -qx "systemctl --user disable --now wave3-watch.service" "$SYSTEMCTL_LOG" && grep -qx "systemctl --user daemon-reload" "$SYSTEMCTL_LOG"'
check "uninstall: prints removed paths" '[[ "$out" == *"removed: $SVC_FILE"* && "$out" == *"removed: $WP_CONF"* ]]'

# --- 7. Second uninstall is idempotent ---
set +e
out="$("$SETUP" uninstall 2>"$TMP/uninstall.err")"
rc=$?
set -e
check "uninstall idempotent: exits 0" '[ "$rc" -eq 0 ] && [ ! -s "$TMP/uninstall.err" ]'
check "uninstall idempotent: reports nothing to remove" '[[ "$out" == *"nothing to remove"* ]]'

# --- 8. link.sh style pre-existing symlinks ---
mkdir -p "$(dirname "$WP_CONF")" "$(dirname "$SVC_FILE")"
# WirePlumber symlink to plugin conf
ln -s "$ROOT/wireplumber/51-elgato-wave3.conf" "$WP_CONF"
# Service symlink to plugin systemd unit
ln -s "$ROOT/systemd/wave3-watch.service" "$SVC_FILE"

out="$("$SETUP" status)"
check "link.sh style: recognized as installed" 'printf "%s\n" "$out" | grep -qx "wireplumber=installed" && printf "%s\n" "$out" | grep -qx "service=installed"'

# Install on link.sh style leaves files alone
out="$("$SETUP" install)"
check "link.sh style: install leaves symlinks untouched" '[ -L "$SVC_FILE" ] && [ "$(readlink -f "$SVC_FILE")" = "$ROOT/systemd/wave3-watch.service" ] && [[ "$out" == *"ok: $SVC_FILE already installed"* ]]'

# Uninstall removes the symlinks, leaves the underlying plugin files intact
out="$("$SETUP" uninstall)"
check "link.sh style: uninstall removes symlinks" '[ ! -e "$SVC_FILE" ] && [ ! -e "$WP_CONF" ]'
check "link.sh style: underlying plugin unit file intact" '[ -f "$ROOT/systemd/wave3-watch.service" ]'
check "link.sh style: underlying plugin wireplumber file intact" '[ -f "$ROOT/wireplumber/51-elgato-wave3.conf" ]'

# --- 9. Identical-content symlink for wireplumber ---
# e.g. user cloned repo elsewhere and linked from there
OTHER_REPO="$TMP/other-repo"
mkdir -p "$OTHER_REPO"
cp "$ROOT/wireplumber/51-elgato-wave3.conf" "$OTHER_REPO/51-elgato-wave3.conf"
ln -s "$OTHER_REPO/51-elgato-wave3.conf" "$WP_CONF"

out="$("$SETUP" status)"
check "identical content symlink: recognized as installed" 'printf "%s\n" "$out" | grep -qx "wireplumber=installed"'
out="$("$SETUP" uninstall)"
check "identical content symlink: removed by uninstall" '[ ! -e "$WP_CONF" ] && [ ! -L "$WP_CONF" ]'
check "identical content symlink: target file untouched" '[ -f "$OTHER_REPO/51-elgato-wave3.conf" ]'

# --- 10. Foreign files are never touched ---
mkdir -p "$(dirname "$WP_CONF")" "$(dirname "$SVC_FILE")"
echo "custom foreign wireplumber config" > "$WP_CONF"
echo "custom foreign systemd unit" > "$SVC_FILE"

out="$("$SETUP" status)"
check "foreign files: recognized as foreign" 'printf "%s\n" "$out" | grep -qx "wireplumber=foreign" && printf "%s\n" "$out" | grep -qx "service=foreign"'

# Install refuses foreign files and exits 1
set +e
out="$("$SETUP" install 2>"$TMP/foreign_install.err")"
rc=$?
set -e
check "foreign install: exits non-zero" '[ "$rc" -ne 0 ]'
check "foreign install: skips wireplumber on stderr" 'grep -q "skip (not ours): $WP_CONF" "$TMP/foreign_install.err"'
check "foreign install: skips service on stderr" 'grep -q "skip (not ours): $SVC_FILE" "$TMP/foreign_install.err"'
check "foreign install: foreign wireplumber file content preserved" '[ "$(cat "$WP_CONF")" = "custom foreign wireplumber config" ]'
check "foreign install: foreign service file content preserved" '[ "$(cat "$SVC_FILE")" = "custom foreign systemd unit" ]'

# Uninstall leaves foreign files alone
set +e
out="$("$SETUP" uninstall 2>"$TMP/foreign_uninstall.err")"
rc=$?
set -e
check "foreign uninstall: exits 0" '[ "$rc" -eq 0 ]'
check "foreign uninstall: foreign wireplumber file not deleted" '[ "$(cat "$WP_CONF")" = "custom foreign wireplumber config" ]'
check "foreign uninstall: foreign service file not deleted" '[ "$(cat "$SVC_FILE")" = "custom foreign systemd unit" ]'
check "foreign uninstall: reports nothing to remove" '[[ "$out" == *"nothing to remove"* ]]'

rm -f "$WP_CONF" "$SVC_FILE"

# --- 11. udev removal note on uninstall when udev=installed ---
touch "$UDEV_DIR/70-elgato-wave3.rules"
out="$("$SETUP" uninstall)"
check "uninstall udev note: prints sudo rm command when udev=installed" 'printf "%s\n" "$out" | grep -qx "sudo rm -f /etc/udev/rules.d/70-elgato-wave3.rules && sudo udevadm control --reload && sudo udevadm trigger"'
rm -f "$UDEV_DIR/70-elgato-wave3.rules"

# --- 12. keep-default command ---
CFG_FILE="$XDG_CONFIG_HOME/abduldotdev.wave3/config"
rm -f "$CFG_FILE"

# Bad args
set +e
err="$("$SETUP" keep-default 2>&1 >/dev/null)"
rc=$?
set -e
check "keep-default: missing arg exits 2" '[ "$rc" -eq 2 ]'
set +e
err="$("$SETUP" keep-default foo 2>&1 >/dev/null)"
rc=$?
set -e
check "keep-default: invalid arg exits 2" '[ "$rc" -eq 2 ]'

# keep-default on
out="$("$SETUP" keep-default on)"
check "keep-default on: prints keep_default=yes" '[ "$out" = "keep_default=yes" ]'
check "keep-default on: config file has keep_default=yes" 'grep -qx "keep_default=yes" "$CFG_FILE"'

# keep-default off
out="$("$SETUP" keep-default off)"
check "keep-default off: prints keep_default=no" '[ "$out" = "keep_default=no" ]'
check "keep-default off: config file has keep_default=no" 'grep -qx "keep_default=no" "$CFG_FILE"'

# Preserves other lines in config
cat > "$CFG_FILE" <<EOF
# Leading comment
unrelated_key=123
keep_default=no
another_setting=hello
EOF

out="$("$SETUP" keep-default on)"
check "keep-default: preserves comments and other keys" 'grep -qx "# Leading comment" "$CFG_FILE" && grep -qx "unrelated_key=123" "$CFG_FILE" && grep -qx "another_setting=hello" "$CFG_FILE" && grep -qx "keep_default=yes" "$CFG_FILE"'

# Status reflects keep_default value
out="$("$SETUP" status)"
check "status: reflects keep_default=yes" 'printf "%s\n" "$out" | grep -qx "keep_default=yes"'
"$SETUP" keep-default off >/dev/null
out="$("$SETUP" status)"
check "status: reflects keep_default=no" 'printf "%s\n" "$out" | grep -qx "keep_default=no"'

# --- 13. Systemctl error during install ---
touch "$SYSTEMCTL_STATE/fail-enable"
set +e
out="$("$SETUP" install 2>"$TMP/install_err.log")"
rc=$?
set -e
check "install: fails with exit 1 if systemctl enable fails" '[ "$rc" -eq 1 ] && grep -q "wave3-setup: failed to enable wave3-watch.service" "$TMP/install_err.log"'
rm -f "$SYSTEMCTL_STATE/fail-enable"
"$SETUP" uninstall >/dev/null

# --- 14. Path with spaces quoting for systemd ExecStart ---
SPACE_ROOT="$TMP/plugin with space"
mkdir -p "$SPACE_ROOT/bin" "$SPACE_ROOT/wireplumber" "$SPACE_ROOT/udev"
cp "$ROOT/bin/wave3-setup" "$SPACE_ROOT/bin/"
cp "$ROOT/wireplumber/51-elgato-wave3.conf" "$SPACE_ROOT/wireplumber/"
cp "$ROOT/udev/70-elgato-wave3.rules" "$SPACE_ROOT/udev/"
chmod +x "$SPACE_ROOT/bin/wave3-setup"
SPACE_HOME="$TMP/home-space"
mkdir -p "$SPACE_HOME"
HOME="$SPACE_HOME" XDG_CONFIG_HOME="$SPACE_HOME/.config" "$SPACE_ROOT/bin/wave3-setup" install >/dev/null
SPACE_SVC="$SPACE_HOME/.config/systemd/user/wave3-watch.service"
check "path with space: ExecStart is quoted" 'grep -qx "ExecStart=\"$SPACE_ROOT/bin/wave3-watch\"" "$SPACE_SVC"'
check "path with space: ConditionPathExists is unquoted" 'grep -qx "ConditionPathExists=$SPACE_ROOT/bin/wave3-watch" "$SPACE_SVC"'

[ "$fails" -eq 0 ] || { echo "$fails test(s) failed"; exit 1; }
echo "all setup tests passed"
