#!/usr/bin/env python3
"""Unit tests for bin/wave3-hw and tests/live-hw.sh."""

import fcntl
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN_WAVE3_HW = os.path.join(REPO_ROOT, "bin", "wave3-hw")
LIVE_HW_SH = os.path.join(REPO_ROOT, "tests", "live-hw.sh")

LIVE_HEX = "00 0a 00 ec 00 01 01 80 eb 00 00 00 01 00 00 01"
LIVE_BYTES = bytes.fromhex(LIVE_HEX)

# Block observed on the live mic after a power cycle (gain 40, lowcut 0, dial 2, gain_lock 0).
POWER_ON_HEX = "00 28 00 ec 00 01 00 80 eb 00 00 00 02 00 00 00"
PRE_REPLUG_STORE = {
    "gain_db": 10.0, "clipguard": 1, "lowcut": 1, "hp_db": -20.5, "hp_mute": 0,
    "direct_monitor": 0, "leds_off": 0, "leds_flip": 0, "gain_lock": 1,
}


def load_wave3_hw_module():
    loader = importlib.machinery.SourceFileLoader("wave3_hw", BIN_WAVE3_HW)
    spec = importlib.util.spec_from_loader("wave3_hw", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class TestWave3HwUnit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_wave3_hw_module()

    def test_decode_live_block(self):
        """Decode exact live block: 00 0a 00 ec 00 01 01 80 eb 00 00 00 01 00 00 01."""
        m = self.mod
        self.assertAlmostEqual(m.decode_field("gain_db", LIVE_BYTES), 10.0)
        self.assertEqual(m.decode_field("mute", LIVE_BYTES), 0)
        self.assertEqual(m.decode_field("clipguard", LIVE_BYTES), 1)
        self.assertEqual(m.decode_field("lowcut", LIVE_BYTES), 1)
        self.assertAlmostEqual(m.decode_field("hp_db", LIVE_BYTES), -20.5)
        self.assertEqual(m.decode_field("hp_mute", LIVE_BYTES), 0)
        self.assertEqual(m.decode_field("direct_monitor", LIVE_BYTES), 0)
        self.assertEqual(m.decode_field("volume_select", LIVE_BYTES), 1)
        self.assertEqual(m.decode_field("leds_off", LIVE_BYTES), 0)
        self.assertEqual(m.decode_field("leds_flip", LIVE_BYTES), 0)
        self.assertEqual(m.decode_field("gain_lock", LIVE_BYTES), 1)

    def test_encode_decode_round_trips(self):
        """Verify encode/decode round trips across field valid ranges."""
        m = self.mod
        base = LIVE_BYTES

        # gain_db
        for gain in (0.0, 0.5, 10.0, 20.5, 39.5, 40.0):
            encoded = m.encode_field("gain_db", gain, base)
            self.assertAlmostEqual(m.decode_field("gain_db", encoded), gain)

        # hp_db
        for hp in (-60.0, -59.5, -20.5, -0.5, 0.0):
            encoded = m.encode_field("hp_db", hp, base)
            self.assertAlmostEqual(m.decode_field("hp_db", encoded), hp)

        # direct_monitor
        for dm in (0, 5, 25, 50, 75, 95, 100):
            encoded = m.encode_field("direct_monitor", dm, base)
            self.assertEqual(m.decode_field("direct_monitor", encoded), dm)

        # volume_select
        for vs in (1, 2, 3):
            encoded = m.encode_field("volume_select", vs, base)
            self.assertEqual(m.decode_field("volume_select", encoded), vs)

        # booleans
        bool_fields = ["mute", "clipguard", "lowcut", "hp_mute", "leds_off", "leds_flip", "gain_lock"]
        for bf in bool_fields:
            for b_val in (0, 1):
                encoded = m.encode_field(bf, b_val, base)
                self.assertEqual(m.decode_field(bf, encoded), b_val)


class TestWave3HwSubprocess(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="wave3_test_")
        self.config_path = os.path.join(self.test_dir, "config")
        self.version_path = os.path.join(self.test_dir, "version")
        with open(self.config_path, "w") as f:
            f.write(LIVE_HEX + "\n")
        with open(self.version_path, "w") as f:
            f.write("5.3\n")
        # Store and lock live outside the fake dir so tests never touch the user's
        # real store or contend with a running popup for the real lock.
        self.state_dir = tempfile.mkdtemp(prefix="wave3_state_")
        self.store_path = os.path.join(self.state_dir, "state", "hw.json")
        self.env = os.environ.copy()
        self.env["WAVE3_HW_FAKE"] = self.test_dir
        self.env["WAVE3_HW_STORE"] = self.store_path
        self.env["XDG_RUNTIME_DIR"] = self.state_dir

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)
        shutil.rmtree(self.state_dir, ignore_errors=True)

    def write_fake(self, name, content):
        with open(os.path.join(self.test_dir, name), "w") as f:
            f.write(content)

    def read_config_hex(self):
        with open(self.config_path, "r") as f:
            return f.read().strip()

    def write_store(self, fields, version=1):
        os.makedirs(os.path.dirname(self.store_path), exist_ok=True)
        with open(self.store_path, "w") as f:
            json.dump({"version": version, "fields": fields}, f)

    def read_store(self):
        with open(self.store_path, "r") as f:
            return json.load(f)

    def count_writes(self):
        path = os.path.join(self.test_dir, "writes")
        if not os.path.exists(path):
            return 0
        with open(path, "r") as f:
            return len(f.read().splitlines())

    @staticmethod
    def kv(stdout):
        return dict(line.split("=", 1) for line in stdout.splitlines() if "=" in line)

    def run_hw(self, *args, check=True, env=None):
        if env is None:
            env = self.env
        return subprocess.run(
            [BIN_WAVE3_HW, *args],
            capture_output=True,
            text=True,
            env=env,
            check=check,
        )

    def test_status_output_format(self):
        """Status prints key=value lines in exact order with expected values."""
        res = self.run_hw("status")
        self.assertEqual(res.returncode, 0)
        lines = res.stdout.strip().split("\n")
        expected_keys = [
            "present", "access", "device", "api", "supported",
            "gain_db", "mute", "clipguard", "lowcut", "hp_db", "hp_mute",
            "direct_monitor", "volume_select", "leds_off", "leds_flip", "gain_lock",
            "raw"
        ]
        self.assertEqual(len(lines), len(expected_keys))
        parsed = {}
        for line, exp_key in zip(lines, expected_keys):
            self.assertIn("=", line)
            k, v = line.split("=", 1)
            self.assertEqual(k, exp_key)
            parsed[k] = v

        self.assertEqual(parsed["present"], "yes")
        self.assertEqual(parsed["access"], "ok")
        self.assertEqual(parsed["device"], f"fake:{self.test_dir}")
        self.assertEqual(parsed["api"], "5.3")
        self.assertEqual(parsed["supported"], "yes")
        self.assertEqual(parsed["gain_db"], "10.0")
        self.assertEqual(parsed["mute"], "0")
        self.assertEqual(parsed["clipguard"], "1")
        self.assertEqual(parsed["lowcut"], "1")
        self.assertEqual(parsed["hp_db"], "-20.5")
        self.assertEqual(parsed["hp_mute"], "0")
        self.assertEqual(parsed["direct_monitor"], "0")
        self.assertEqual(parsed["volume_select"], "1")
        self.assertEqual(parsed["leds_off"], "0")
        self.assertEqual(parsed["leds_flip"], "0")
        self.assertEqual(parsed["gain_lock"], "1")
        self.assertEqual(parsed["raw"], LIVE_HEX)

    def test_set_changes_only_target_bytes(self):
        """Each set modifies only target bytes and preserves reserved bytes 2-3 and others."""
        mod = load_wave3_hw_module()
        changes = [
            ("gain_db", "25.5"),
            ("mute", "1"),
            ("clipguard", "0"),
            ("lowcut", "0"),
            ("hp_db", "-15.0"),
            ("hp_mute", "1"),
            ("direct_monitor", "45"),
            ("volume_select", "2"),
            ("leds_off", "1"),
            ("leds_flip", "1"),
            ("gain_lock", "0"),
        ]

        for field, new_val_str in changes:
            # Reinitialize config with LIVE_HEX
            with open(self.config_path, "w") as f:
                f.write(LIVE_HEX + "\n")

            res = self.run_hw("set", field, new_val_str)
            self.assertEqual(res.returncode, 0)

            # Read back config
            with open(self.config_path, "r") as f:
                updated_bytes = bytes.fromhex(f.read().strip())

            spec = mod.FIELD_SPECS[field]
            offset = spec["offset"]
            size = spec["size"]

            # Target bytes changed
            self.assertNotEqual(updated_bytes[offset : offset + size], LIVE_BYTES[offset : offset + size])

            # All other bytes identical
            for idx in range(16):
                if offset <= idx < offset + size:
                    continue
                self.assertEqual(
                    updated_bytes[idx],
                    LIVE_BYTES[idx],
                    f"Byte at index {idx} modified when setting {field}"
                )

            # Reserved bytes 2-3 untouched
            self.assertEqual(updated_bytes[2:4], LIVE_BYTES[2:4])

    def test_clamp_and_quantize(self):
        """Numbers are clamped and quantized according to field spec."""
        # gain_db: clamp [0.0, 40.0], quantize 0.5
        res = self.run_hw("set", "gain_db", "41")
        self.assertEqual(res.stdout.splitlines()[0], "gain_db=40.0")

        res = self.run_hw("set", "gain_db", "10.3")
        self.assertEqual(res.stdout.splitlines()[0], "gain_db=10.5")

        res = self.run_hw("set", "gain_db", "-5")
        self.assertEqual(res.stdout.splitlines()[0], "gain_db=0.0")

        # hp_db: clamp [-60.0, 0.0], quantize 0.5
        res = self.run_hw("set", "hp_db", "-61")
        self.assertEqual(res.stdout.splitlines()[0], "hp_db=-60.0")

        res = self.run_hw("set", "hp_db", "5")
        self.assertEqual(res.stdout.splitlines()[0], "hp_db=0.0")

        # direct_monitor: clamp [0, 100], quantize 5
        res = self.run_hw("set", "direct_monitor", "7")
        self.assertEqual(res.stdout.splitlines()[0], "direct_monitor=5")

        res = self.run_hw("set", "direct_monitor", "104")
        self.assertEqual(res.stdout.splitlines()[0], "direct_monitor=100")

        res = self.run_hw("set", "direct_monitor", "-10")
        self.assertEqual(res.stdout.splitlines()[0], "direct_monitor=0")

        # volume_select: mic, headphone, mix
        res = self.run_hw("set", "volume_select", "mic")
        self.assertEqual(res.stdout.splitlines()[0], "volume_select=1")
        res = self.run_hw("set", "volume_select", "headphone")
        self.assertEqual(res.stdout.splitlines()[0], "volume_select=2")
        res = self.run_hw("set", "volume_select", "mix")
        self.assertEqual(res.stdout.splitlines()[0], "volume_select=3")

        # booleans: accept 0 1 on off yes no true false
        for val, exp in [("on", "1"), ("off", "0"), ("yes", "1"), ("no", "0"), ("true", "1"), ("false", "0"), ("1", "1"), ("0", "0")]:
            res = self.run_hw("set", "clipguard", val)
            self.assertEqual(res.stdout.splitlines()[0], f"clipguard={exp}")

    def test_usage_lists_all_commands(self):
        """No args prints the full usage line and exits 2."""
        res = self.run_hw(check=False)
        self.assertEqual(res.returncode, 2)
        self.assertEqual(
            res.stderr.strip(),
            "wave3-hw: usage: wave3-hw status | set <field> <value> | apply [--settle SECONDS] [--retries N] | save | forget",
        )

    def test_bad_field_or_value_exit_2(self):
        """Invalid fields, invalid values, and bad usage exit 2."""
        cases = [
            ("set", "invalid_field", "10"),
            ("set", "reserved", "0"),
            ("set", "gain_db", "notanumber"),
            ("set", "clipguard", "maybe"),
            ("set", "volume_select", "speaker"),
            ("set", "gain_db"),  # missing arg
            ("unknown_cmd",),
            (),  # no args
        ]
        for c in cases:
            res = self.run_hw(*c, check=False)
            self.assertEqual(res.returncode, 2, f"Failed on args: {c}")
            self.assertTrue(res.stderr.startswith("wave3-hw:"))

    def test_device_absent_exit_3(self):
        """Missing fake dir causes present=no on status, exit 3 on set."""
        missing_dir = os.path.join(self.test_dir, "nonexistent")
        env = self.env.copy()
        env["WAVE3_HW_FAKE"] = missing_dir

        res = self.run_hw("status", env=env)
        self.assertEqual(res.returncode, 0)
        lines = res.stdout.strip().split("\n")
        self.assertIn("present=no", lines)
        self.assertIn("access=", lines)
        self.assertIn("device=", lines)
        self.assertIn("api=", lines)
        self.assertIn("supported=no", lines)

        res_set = self.run_hw("set", "gain_db", "10", check=False, env=env)
        self.assertEqual(res_set.returncode, 3)
        self.assertTrue(res_set.stderr.startswith("wave3-hw:"))

    def test_permission_denied_exit_4(self):
        """Presence of 'denied' file causes access=denied on status and exit 4 on set with udev hint."""
        denied_file = os.path.join(self.test_dir, "denied")
        open(denied_file, "w").close()

        res = self.run_hw("status")
        self.assertEqual(res.returncode, 0)
        lines = res.stdout.strip().split("\n")
        self.assertIn("present=yes", lines)
        self.assertIn("access=denied", lines)
        self.assertIn(f"device=fake:{self.test_dir}", lines)
        self.assertIn("api=", lines)
        self.assertIn("supported=no", lines)

        res_set = self.run_hw("set", "gain_db", "10", check=False)
        self.assertEqual(res_set.returncode, 4)
        self.assertTrue(res_set.stderr.startswith("wave3-hw:"))
        self.assertIn("sudo install -m644", res_set.stderr)
        self.assertIn("70-elgato-wave3.rules", res_set.stderr)

    def test_version_gate(self):
        """API version other than 5.3 or 5.4 causes supported=no and set exit 5 with block untouched."""
        for unsupported_ver in ("5.2", "5.5"):
            with open(self.version_path, "w") as f:
                f.write(unsupported_ver + "\n")
            with open(self.config_path, "w") as f:
                f.write(LIVE_HEX + "\n")

            res_status = self.run_hw("status")
            self.assertEqual(res_status.returncode, 0)
            self.assertIn(f"api={unsupported_ver}", res_status.stdout)
            self.assertIn("supported=no", res_status.stdout)

            res_set = self.run_hw("set", "gain_db", "20", check=False)
            self.assertEqual(res_set.returncode, 5)
            self.assertTrue(res_set.stderr.startswith("wave3-hw:"))

            # Verify block remains untouched
            with open(self.config_path, "r") as f:
                self.assertEqual(f.read().strip(), LIVE_HEX)

        # Version 5.4 is supported
        with open(self.version_path, "w") as f:
            f.write("5.4\n")
        res_status = self.run_hw("status")
        self.assertIn("api=5.4", res_status.stdout)
        self.assertIn("supported=yes", res_status.stdout)
        res_set = self.run_hw("set", "gain_db", "20.0")
        self.assertEqual(res_set.returncode, 0)

    def test_readonly_fake_exit_6(self):
        """Readonly fake causes read-back mismatch and exit code 6."""
        readonly_file = os.path.join(self.test_dir, "readonly")
        open(readonly_file, "w").close()

        res_set = self.run_hw("set", "gain_db", "30.0", check=False)
        self.assertEqual(res_set.returncode, 6)
        self.assertTrue(res_set.stderr.startswith("wave3-hw:"))

    def test_live_hw_script_passes_on_fake(self):
        """tests/live-hw.sh succeeds on valid fake, leaving config block identical to start."""
        with open(self.config_path, "w") as f:
            f.write(LIVE_HEX + "\n")

        res = subprocess.run(
            ["bash", LIVE_HW_SH],
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertEqual(res.returncode, 0, f"live-hw.sh failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}")
        self.assertIn("field", res.stdout)
        self.assertIn("original", res.stdout)
        self.assertIn("changed", res.stdout)
        self.assertIn("restored", res.stdout)
        self.assertIn("result", res.stdout)

        # Block at end must be identical to start
        with open(self.config_path, "r") as f:
            self.assertEqual(f.read().strip(), LIVE_HEX)

    def test_live_hw_script_fails_on_readonly(self):
        """tests/live-hw.sh fails non-zero on readonly fake, leaving block unchanged."""
        with open(self.config_path, "w") as f:
            f.write(LIVE_HEX + "\n")
        readonly_file = os.path.join(self.test_dir, "readonly")
        open(readonly_file, "w").close()

        res = subprocess.run(
            ["bash", LIVE_HW_SH],
            capture_output=True,
            text=True,
            env=self.env,
        )
        self.assertNotEqual(res.returncode, 0)

        # Block unchanged
        with open(self.config_path, "r") as f:
            self.assertEqual(f.read().strip(), LIVE_HEX)

    def test_live_hw_script_rollback_on_failed_change_write(self):
        """Simulate a failing change write that landed on device; verify rollback restores start block."""
        with open(self.config_path, "w") as f:
            f.write(LIVE_HEX + "\n")

        wrapper_path = os.path.join(self.test_dir, "failing_wave3_hw.sh")
        wrapper_content = f"""#!/usr/bin/env bash
REAL_BIN="{BIN_WAVE3_HW}"
if [[ "$1" == "set" && "$2" == "clipguard" && "$3" == "0" ]]; then
  # Simulate successful write landing on device but readback verification failing with exit 6
  "$REAL_BIN" "$@" >/dev/null 2>&1
  echo "wave3-hw: simulated read-back verification failed for field 'clipguard'" >&2
  exit 6
fi
exec "$REAL_BIN" "$@"
"""
        with open(wrapper_path, "w") as f:
            f.write(wrapper_content)
        os.chmod(wrapper_path, 0o755)

        env = self.env.copy()
        env["WAVE3_HW"] = wrapper_path

        res = subprocess.run(
            ["bash", LIVE_HW_SH],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertNotEqual(res.returncode, 0, "live-hw.sh should have exited non-zero on simulated error")
        self.assertIn("mismatch or error on 'clipguard'", res.stderr)

        # Assert the final block equals the start block (rollback restored clipguard=1)
        with open(self.config_path, "r") as f:
            self.assertEqual(f.read().strip(), LIVE_HEX)

    def test_live_hw_script_uses_temp_store_when_unset(self):
        """tests/live-hw.sh never writes the default store when WAVE3_HW_STORE is unset."""
        home = os.path.join(self.state_dir, "home")
        os.makedirs(home)
        env = self.env.copy()
        del env["WAVE3_HW_STORE"]
        env.pop("XDG_STATE_HOME", None)
        env["HOME"] = home
        res = subprocess.run(["bash", LIVE_HW_SH], capture_output=True, text=True, env=env)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertFalse(os.path.exists(os.path.join(home, ".local", "state", "abduldotdev.wave3")))

    # T-1
    def test_apply_restores_from_power_on_block(self):
        """apply restores the pre-replug store onto the observed power-on block in one write."""
        self.write_fake("config", POWER_ON_HEX + "\n")
        self.write_store(PRE_REPLUG_STORE)

        res = self.run_hw("apply", check=False)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(
            res.stdout.splitlines(),
            ["store=ok", "changed=gain_db,lowcut,gain_lock", "reapplied=", "result=applied"],
        )
        config = self.read_config_hex()
        self.assertEqual(config, "00 0a 00 ec 00 01 01 80 eb 00 00 00 02 00 00 01")
        raw = bytes.fromhex(config)
        self.assertEqual(raw[2:4], b"\x00\xec")
        self.assertEqual(raw[4], 0)
        self.assertEqual(raw[12], 2)
        self.assertEqual(self.count_writes(), 1)

    # T-2
    def test_apply_noop_when_device_matches_store(self):
        """A second apply writes nothing and reports noop."""
        self.write_fake("config", POWER_ON_HEX + "\n")
        self.write_store(PRE_REPLUG_STORE)
        self.run_hw("apply")

        res = self.run_hw("apply", check=False)
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.splitlines(), ["store=ok", "changed=", "reapplied=", "result=noop"])
        self.assertEqual(self.count_writes(), 1)

    # T-3
    def test_apply_missing_store_is_noop_without_device(self):
        """Missing store is a no-op and never opens the device."""
        env = self.env.copy()
        env["WAVE3_HW_FAKE"] = os.path.join(self.test_dir, "nonexistent")
        res = self.run_hw("apply", check=False, env=env)
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.splitlines(), ["store=missing", "changed=", "reapplied=", "result=noop"])

    def test_apply_empty_store_is_noop(self):
        """A store with no usable fields behaves like missing but reports store=ok."""
        self.write_store({})
        res = self.run_hw("apply", check=False)
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.splitlines(), ["store=ok", "changed=", "reapplied=", "result=noop"])
        self.assertEqual(self.count_writes(), 0)

    def test_apply_corrupt_store_exit_7(self):
        """Corrupt stores exit 7 without touching the device."""
        self.write_fake("config", POWER_ON_HEX + "\n")
        os.makedirs(os.path.dirname(self.store_path))
        for content in ("{", "[]", '{"version":2,"fields":{}}', '{"version":1,"fields":[]}'):
            with open(self.store_path, "w") as f:
                f.write(content)
            res = self.run_hw("apply", check=False)
            self.assertEqual(res.returncode, 7, content)
            self.assertEqual(res.stdout.splitlines(), ["store=corrupt", "changed=", "reapplied=", "result=error"])
            self.assertEqual(self.read_config_hex(), POWER_ON_HEX)
        self.assertEqual(self.count_writes(), 0)

    def test_apply_skips_invalid_field(self):
        """An invalid field value is skipped with a stderr line while others apply."""
        self.write_fake("config", POWER_ON_HEX + "\n")
        self.write_store({"gain_db": "abc", "lowcut": 1})
        res = self.run_hw("apply", check=False)
        self.assertEqual(res.returncode, 0)
        self.assertIn("wave3-hw: store: ignoring gain_db", res.stderr)
        self.assertEqual(self.kv(res.stdout)["changed"], "lowcut")
        self.assertEqual(self.read_config_hex(), "00 28 00 ec 00 01 01 80 eb 00 00 00 02 00 00 00")

    def test_apply_ignores_mute_and_volume_select(self):
        """mute/volume_select keys in the store never reach bytes 4 and 12."""
        self.write_fake("config", POWER_ON_HEX + "\n")
        self.write_store({"mute": 1, "volume_select": 3, "raw": "ff", "lowcut": 0})
        res = self.run_hw("apply", check=False)
        self.assertEqual(res.returncode, 0)
        self.assertEqual(self.kv(res.stdout)["result"], "noop")
        self.assertEqual(self.read_config_hex(), POWER_ON_HEX)
        self.assertEqual(self.count_writes(), 0)

    def test_apply_device_errors(self):
        """Absent 3, denied 4, unsupported 5, readonly mismatch 6."""
        self.write_fake("config", POWER_ON_HEX + "\n")
        self.write_store(PRE_REPLUG_STORE)

        env = self.env.copy()
        env["WAVE3_HW_FAKE"] = os.path.join(self.test_dir, "nonexistent")
        res = self.run_hw("apply", check=False, env=env)
        self.assertEqual(res.returncode, 3)
        self.assertEqual(self.kv(res.stdout)["result"], "absent")

        self.write_fake("denied", "")
        res = self.run_hw("apply", check=False)
        self.assertEqual(res.returncode, 4)
        self.assertEqual(self.kv(res.stdout)["result"], "denied")
        os.unlink(os.path.join(self.test_dir, "denied"))

        self.write_fake("version", "5.5\n")
        res = self.run_hw("apply", check=False)
        self.assertEqual(res.returncode, 5)
        self.assertEqual(self.kv(res.stdout)["result"], "unsupported")
        self.write_fake("version", "5.3\n")

        self.write_fake("readonly", "")
        res = self.run_hw("apply", check=False)
        self.assertEqual(res.returncode, 6)
        self.assertEqual(self.kv(res.stdout)["result"], "mismatch")
        self.assertIn("wave3-hw: apply attempt 0:", res.stderr)
        self.assertEqual(self.read_config_hex(), POWER_ON_HEX)

    # T-4
    def test_busy_retry_recovers(self):
        """A few EBUSY failures are retried: status is ok and set succeeds."""
        self.write_fake("busy", "3\n")
        res = self.run_hw("status")
        self.assertIn("access=ok", res.stdout.splitlines())

        self.write_fake("busy", "3\n")
        res = self.run_hw("set", "lowcut", "0", check=False)
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_busy_exhausted_reports_busy(self):
        """Persistent EBUSY gives status error=busy (rc 0) and set exit 8."""
        self.write_fake("busy", "1000\n")
        res = self.run_hw("status")
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout, "error=busy\n")

        res = self.run_hw("set", "lowcut", "0", check=False)
        self.assertEqual(res.returncode, 8)
        self.assertTrue(res.stderr.startswith("wave3-hw:"))

    def test_lock_timeout_reports_busy(self):
        """A held device lock makes status print error=busy and forget exit 8."""
        fd = os.open(os.path.join(self.state_dir, "wave3-hw.lock"), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            res = self.run_hw("status")
            self.assertEqual(res.stdout, "error=busy\n")
            res = self.run_hw("forget", check=False)
            self.assertEqual(res.returncode, 8)
        finally:
            os.close(fd)

    def test_apply_drift_settle_reapplies(self):
        """A late drift after the first read-back is re-applied in a settle round."""
        self.write_fake("config", POWER_ON_HEX + "\n")
        self.write_fake("drift", "00 28 00 ec 00 01 01 80 eb 00 00 00 02 00 00 01\n")
        self.write_store(PRE_REPLUG_STORE)

        res = self.run_hw("apply", "--settle", "0.1", "--retries=1", check=False)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(
            res.stdout.splitlines(),
            ["store=ok", "changed=gain_db,lowcut,gain_lock", "reapplied=gain_db", "result=applied"],
        )
        self.assertEqual(self.read_config_hex(), "00 0a 00 ec 00 01 01 80 eb 00 00 00 02 00 00 01")
        self.assertEqual(self.count_writes(), 2)

    def test_apply_bad_flags_exit_2(self):
        """Out of range or unparsable apply flags exit 2."""
        for args in (("--settle", "-1"), ("--settle", "31"), ("--retries", "11"), ("--settle", "x"),
                     ("--retries=-1",), ("--settle",), ("--bogus", "1")):
            res = self.run_hw("apply", *args, check=False)
            self.assertEqual(res.returncode, 2, args)
            self.assertTrue(res.stderr.startswith("wave3-hw:"))

    # T-5
    def test_set_records_to_store(self):
        """set on a stored field writes the canonical value atomically with 0600/0700 modes."""
        res = self.run_hw("set", "lowcut", "1")
        self.assertEqual(res.stdout.splitlines(), ["lowcut=1", "saved=yes"])
        self.assertEqual(self.read_store(), {"version": 1, "fields": {"lowcut": 1}})
        store_dir = os.path.dirname(self.store_path)
        self.assertEqual(os.stat(self.store_path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(store_dir).st_mode & 0o777, 0o700)
        self.assertEqual(os.listdir(store_dir), ["hw.json"])

        res = self.run_hw("set", "gain_db", "12.3")
        self.assertEqual(res.stdout.splitlines(), ["gain_db=12.5", "saved=yes"])
        self.assertEqual(self.read_store()["fields"], {"gain_db": 12.5, "lowcut": 1})

    def test_set_unstored_fields_not_saved(self):
        """mute and volume_select print saved=no and are never recorded."""
        for field, value in (("mute", "1"), ("volume_select", "mix")):
            res = self.run_hw("set", field, value)
            self.assertEqual(res.stdout.splitlines()[1], "saved=no")
        self.assertFalse(os.path.exists(self.store_path))

    def test_failed_set_leaves_store(self):
        """A failed set leaves the store unchanged and prints no saved= line."""
        self.write_store({"lowcut": 1})
        env = self.env.copy()
        env["WAVE3_HW_FAKE"] = os.path.join(self.test_dir, "nonexistent")
        res = self.run_hw("set", "lowcut", "0", check=False, env=env)
        self.assertEqual(res.returncode, 3)
        self.assertNotIn("saved=", res.stdout)
        self.assertEqual(self.read_store()["fields"], {"lowcut": 1})

    def test_set_store_write_failure_saved_error(self):
        """A store whose parent is a regular file gives saved=error with exit 0."""
        blocker = os.path.join(self.state_dir, "blocker")
        open(blocker, "w").close()
        env = self.env.copy()
        env["WAVE3_HW_STORE"] = os.path.join(blocker, "hw.json")
        res = self.run_hw("set", "lowcut", "0", check=False, env=env)
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.splitlines(), ["lowcut=0", "saved=error"])
        self.assertIn("wave3-hw: could not save setting:", res.stderr)

    def test_set_replaces_corrupt_store(self):
        """set over a corrupt store replaces it with a valid one."""
        os.makedirs(os.path.dirname(self.store_path))
        with open(self.store_path, "w") as f:
            f.write("{")
        res = self.run_hw("set", "clipguard", "0")
        self.assertEqual(res.stdout.splitlines(), ["clipguard=0", "saved=yes"])
        self.assertEqual(self.read_store(), {"version": 1, "fields": {"clipguard": 0}})

    # T-6
    def test_save_and_forget(self):
        """save snapshots the nine stored fields; forget removes the store."""
        res = self.run_hw("save")
        self.assertEqual(res.stdout.splitlines(), [
            "gain_db=10.0", "clipguard=1", "lowcut=1", "hp_db=-20.5", "hp_mute=0",
            "direct_monitor=0", "leds_off=0", "leds_flip=0", "gain_lock=1", "saved=yes",
        ])
        self.assertEqual(self.read_store(), {"version": 1, "fields": PRE_REPLUG_STORE})

        res = self.run_hw("forget")
        self.assertEqual(res.stdout, "forgotten=yes\n")
        self.assertFalse(os.path.exists(self.store_path))
        res = self.run_hw("forget")
        self.assertEqual(res.stdout, "forgotten=no\n")

    def test_forget_works_without_device(self):
        """forget needs no device access."""
        self.write_store({"lowcut": 1})
        env = self.env.copy()
        env["WAVE3_HW_FAKE"] = os.path.join(self.test_dir, "nonexistent")
        res = self.run_hw("forget", env=env)
        self.assertEqual(res.stdout, "forgotten=yes\n")

    def test_status_and_apply_never_write_store(self):
        """status and apply leave the store untouched."""
        self.write_fake("config", POWER_ON_HEX + "\n")
        self.write_store({"lowcut": 1})
        before = os.stat(self.store_path).st_mtime_ns
        self.run_hw("status")
        self.run_hw("apply")
        self.assertEqual(os.stat(self.store_path).st_mtime_ns, before)
        self.assertEqual(self.read_store(), {"version": 1, "fields": {"lowcut": 1}})


if __name__ == "__main__":
    unittest.main()
