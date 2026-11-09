"""Release metadata and a signed Sparkle appcast for a notarized DMG."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def metadata(env):
    ref = env["GITHUB_REF"]
    run = env["GITHUB_RUN_NUMBER"]
    attempt = env["GITHUB_RUN_ATTEMPT"]
    if not re.fullmatch(r"[1-9][0-9]*", run) or not re.fullmatch(r"[1-9][0-9]*", attempt):
        raise ValueError("Release run and attempt must be positive numbers")
    build = f"{run}.{attempt}"
    if ref.startswith("refs/tags/v"):
        version = ref.removeprefix("refs/tags/v")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
            raise ValueError("Stable tags must use vMAJOR.MINOR.PATCH")
        channel, tag = "stable", f"v{version}"
    elif ref == "refs/heads/master":
        channel, tag = "nightly", "nightly"
        version = f"nightly-{build}"
    else:
        raise ValueError("Release builds require a stable tag or master")
    return {"YOYO_VERSION": version, "YOYO_BUILD_VERSION": build,
            "YOYO_UPDATE_CHANNEL": channel, "YOYO_RELEASE_TAG": tag,
            "OUTPUT_DMG": f"build/Yoyo-{version}-{build}.dmg"}


def appcast(info, signature, length, repository):
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("Invalid GitHub repository")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid Ed25519 signature")
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = f"Yoyo {info['YOYO_UPDATE_CHANNEL']}"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Yoyo {info['YOYO_VERSION']}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = info["YOYO_BUILD_VERSION"]
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = info["YOYO_VERSION"]
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0.0"
    ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "description").text = (
        "Nightly build from master." if info["YOYO_UPDATE_CHANNEL"] == "nightly" else "Stable release.")
    release = f"https://github.com/{repository}/releases"
    ET.SubElement(item, "link").text = f"{release}/tag/{info['YOYO_RELEASE_TAG']}"
    ET.SubElement(item, "enclosure", {
        "url": f"{release}/download/{info['YOYO_RELEASE_TAG']}/{Path(info['OUTPUT_DMG']).name}",
        f"{{{SPARKLE}}}edSignature": signature, "length": str(length),
        "type": "application/octet-stream"})
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def main():
    if sys.argv[1] == "metadata":
        info = metadata(os.environ)
        Path("build").mkdir(exist_ok=True)
        Path("build/release.json").write_text(json.dumps(info))
        with open(os.environ["GITHUB_ENV"], "a") as output:
            output.write("".join(f"{key}={value}\n" for key, value in info.items()))
    elif sys.argv[1] == "sign":
        info = json.loads(Path("build/release.json").read_text())
        dmg = Path(info["OUTPUT_DMG"])
        signature = subprocess.run(
            ["build/dependencies/sparkle/bin/sign_update", "--ed-key-file", "-", "-p", str(dmg)],
            input=os.environ["SPARKLE_PRIVATE_KEY"], text=True, capture_output=True, check=True).stdout.strip()
        # Verify against the public key embedded in the app, catching misconfigured CI keys.
        subprocess.run(["/usr/bin/swift", "scripts/release/verify-signature.swift", str(dmg),
                        os.environ["SPARKLE_PUBLIC_KEY"], signature], check=True)
        Path("build/appcast.xml").write_bytes(appcast(info, signature, dmg.stat().st_size, os.environ["GITHUB_REPOSITORY"]))
    else:
        raise ValueError("Expected metadata or sign")


if __name__ == "__main__":
    main()
