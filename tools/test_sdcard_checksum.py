# SPDX-License-Identifier: GPL-2.0-only
from binascii import crc_hqx
from pathlib import Path
import unittest


class SdcardChecksumTests(unittest.TestCase):
    def test_radio_fixture_checksum_matches_companion(self):
        # EdgeTX 2.12: companion/src/firmwares/edgetx/edgetxinterface.cpp,
        # calculateChecksum: skip the first line, CRC16-CCITT seeded with 0xFFFF.
        path = Path(__file__).resolve().parents[1] / "tests/fixtures/sdcard/RADIO/radio.yml"
        header, body = path.read_bytes().split(b"\n", 1)
        self.assertTrue(header.startswith(b"checksum:"))
        stored = int(header.split(b":", 1)[1])
        calculated = crc_hqx(body, 0xFFFF)
        self.assertEqual(stored, calculated,
                         f"Radio fixture checksum is stale; update its first line to checksum: {calculated}")


if __name__ == "__main__":
    unittest.main()
