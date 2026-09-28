#!/usr/bin/env python3
"""Unit tests for bin/wave3-hw and tests/live-hw.sh."""

import importlib.machinery
import importlib.util
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
        self.env = os.environ.copy()
        self.env["WAVE3_HW_FAKE"] = self.test_dir

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

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
        self.assertEqual(res.stdout.strip(), "gain_db=40.0")

        res = self.run_hw("set", "gain_db", "10.3")
        self.assertEqual(res.stdout.strip(), "gain_db=10.5")

        res = self.run_hw("set", "gain_db", "-5")
        self.assertEqual(res.stdout.strip(), "gain_db=0.0")

        # hp_db: clamp [-60.0, 0.0], quantize 0.5
        res = self.run_hw("set", "hp_db", "-61")
        self.assertEqual(res.stdout.strip(), "hp_db=-60.0")

        res = self.run_hw("set", "hp_db", "5")
        self.assertEqual(res.stdout.strip(), "hp_db=0.0")

        # direct_monitor: clamp [0, 100], quantize 5
        res = self.run_hw("set", "direct_monitor", "7")
        self.assertEqual(res.stdout.strip(), "direct_monitor=5")

        res = self.run_hw("set", "direct_monitor", "104")
        self.assertEqual(res.stdout.strip(), "direct_monitor=100")

        res = self.run_hw("set", "direct_monitor", "-10")
        self.assertEqual(res.stdout.strip(), "direct_monitor=0")

        # volume_select: mic, headphone, mix
        res = self.run_hw("set", "volume_select", "mic")
        self.assertEqual(res.stdout.strip(), "volume_select=1")
        res = self.run_hw("set", "volume_select", "headphone")
        self.assertEqual(res.stdout.strip(), "volume_select=2")
        res = self.run_hw("set", "volume_select", "mix")
        self.assertEqual(res.stdout.strip(), "volume_select=3")

        # booleans: accept 0 1 on off yes no true false
        for val, exp in [("on", "1"), ("off", "0"), ("yes", "1"), ("no", "0"), ("true", "1"), ("false", "0"), ("1", "1"), ("0", "0")]:
            res = self.run_hw("set", "clipguard", val)
            self.assertEqual(res.stdout.strip(), f"clipguard={exp}")

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


if __name__ == "__main__":
    unittest.main()
