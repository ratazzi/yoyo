import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("appcast", Path(__file__).parents[2] / "scripts/release/appcast.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
publish_spec = importlib.util.spec_from_file_location("publish", Path(__file__).parents[2] / "scripts/release/publish.py")
publish = importlib.util.module_from_spec(publish_spec)
publish_spec.loader.exec_module(publish)


class UpdateReleaseTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin" and Path("build/dependencies/sparkle/bin/sign_update").exists(), "Requires Sparkle tools on macOS")
    def test_signature_matches_embedded_public_key(self):
        # Public RFC 8032 test vector, never a release signing key.
        seed = base64.b64encode(bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")).decode()
        public = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "update.dmg"
            archive.write_bytes(b"Signed update fixture")
            signature = subprocess.check_output(["build/dependencies/sparkle/bin/sign_update", "--ed-key-file", "-", "-p", str(archive)], input=seed, text=True).strip()
            command = ["/usr/bin/swift", "scripts/release/verify-signature.swift", str(archive), public, signature]
            subprocess.run(command, check=True, capture_output=True)
            archive.write_bytes(b"Tampered update fixture")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def info(self, ref="refs/heads/master", run="100", attempt="1"):
        return module.metadata({"GITHUB_REF": ref, "GITHUB_RUN_NUMBER": run, "GITHUB_RUN_ATTEMPT": attempt})

    def test_channels_and_order(self):
        nightly = self.info()
        stable = self.info("refs/tags/v1.2.3", run="101")
        self.assertEqual(nightly["YOYO_UPDATE_CHANNEL"], "nightly")
        self.assertEqual(stable["YOYO_VERSION"], "1.2.3")
        self.assertEqual(stable["YOYO_UPDATE_CHANNEL"], "stable")
        self.assertNotEqual(nightly["OUTPUT_DMG"], self.info(attempt="2")["OUTPUT_DMG"])
        self.assertEqual(nightly["YOYO_BUILD_VERSION"], "100.1")
        for ref in ("refs/heads/topic", "refs/tags/v1.0-beta", "refs/tags/v1.2.3\nBAD=x"):
            with self.assertRaises(ValueError):
                self.info(ref)
        with self.assertRaises(ValueError):
            self.info(run="0")

    def test_appcast_points_to_exact_signed_archive(self):
        signature = base64.b64encode(bytes(64)).decode()
        for ref in ("refs/heads/master", "refs/tags/v1.2.3"):
            info = self.info(ref)
            feed = ET.fromstring(module.appcast(info, signature, 12345, "ratazzi/yoyo"))
            enclosure = feed.find("channel/item/enclosure")
            self.assertEqual(enclosure.get("url"), f"https://github.com/ratazzi/yoyo/releases/download/{info['YOYO_RELEASE_TAG']}/{Path(info['OUTPUT_DMG']).name}")
            self.assertEqual(enclosure.get("length"), "12345")
            self.assertEqual(enclosure.get(f"{{{module.SPARKLE}}}edSignature"), signature)
            self.assertEqual(feed.findtext(f"channel/item/{{{module.SPARKLE}}}version"), info["YOYO_BUILD_VERSION"])
            self.assertEqual(feed.findtext(f"channel/item/{{{module.SPARKLE}}}hardwareRequirements"), "arm64")
        with self.assertRaises(ValueError):
            module.appcast(self.info(), "invalid", 1, "ratazzi/yoyo")

    def test_publication_orders_archive_before_feed(self):
        info = self.info()
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            try:
                os.chdir(directory)
                Path("artifacts").mkdir()
                Path("artifacts/release.json").write_text(json.dumps(info))
                response = subprocess.CompletedProcess([], 0, json.dumps({"assets": []}), "")
                with patch.dict(os.environ, {"GITHUB_REPOSITORY": "ratazzi/yoyo", "GITHUB_SHA": "abc"}), \
                     patch.object(publish.subprocess, "run", return_value=response), patch.object(publish, "gh") as gh:
                    publish.main()
                    uploads = [call.args for call in gh.call_args_list if call.args[:2] == ("release", "upload")]
                    self.assertEqual(len(uploads), 2)
                    self.assertTrue(uploads[0][3].endswith(".dmg"))
                    self.assertNotIn("--clobber", uploads[0])
                    self.assertEqual(uploads[1][3], "artifacts/appcast.xml")
                    self.assertIn("--clobber", uploads[1])
            finally:
                os.chdir(previous)

    def test_stale_nightly_does_not_publish(self):
        info = self.info()
        with tempfile.TemporaryDirectory() as directory:
            previous = Path.cwd()
            try:
                os.chdir(directory)
                Path("artifacts").mkdir()
                Path("artifacts/release.json").write_text(json.dumps(info))
                response = subprocess.CompletedProcess([], 0, json.dumps({"assets": [{"name": "appcast.xml"}]}), "")
                def download(*args):
                    self.assertEqual(args[:2], ("release", "download"))
                    feed = module.appcast(self.info(run="101"), base64.b64encode(bytes(64)).decode(), 1, "ratazzi/yoyo")
                    (Path(args[-1]) / "appcast.xml").write_bytes(feed)
                with patch.dict(os.environ, {"GITHUB_REPOSITORY": "ratazzi/yoyo", "GITHUB_SHA": "abc"}), \
                     patch.object(publish.subprocess, "run", return_value=response), patch.object(publish, "gh", side_effect=download) as gh:
                    with self.assertRaisesRegex(RuntimeError, "newer nightly"):
                        publish.main()
                    self.assertEqual(gh.call_count, 1)
            finally:
                os.chdir(previous)


unittest.main()
