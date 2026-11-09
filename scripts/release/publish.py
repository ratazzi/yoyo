"""Publish immutable update archives before replacing the nightly appcast."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def main():
    info = json.loads(Path("artifacts/release.json").read_text())
    repository = os.environ["GITHUB_REPOSITORY"]
    tag = info["YOYO_RELEASE_TAG"]
    dmg = str(Path("artifacts") / Path(info["OUTPUT_DMG"]).name)
    archive_exists = False
    if info["YOYO_UPDATE_CHANNEL"] == "stable":
        gh("release", "create", tag, dmg, "artifacts/appcast.xml", "--repo", repository, "--draft", "--generate-notes", "--verify-tag")
        return

    # An older queued workflow must not replace a newer nightly feed.
    result = subprocess.run(["gh", "api", f"repos/{repository}/releases/tags/nightly"], text=True, capture_output=True)
    if result.returncode:
        if "404" not in result.stderr:
            raise RuntimeError(result.stderr)
        gh("release", "create", "nightly", "--repo", repository, "--target", os.environ["GITHUB_SHA"],
           "--title", "Yoyo Nightly", "--notes", "Signed and notarized nightly builds.", "--prerelease", "--latest=false")
    else:
        release = json.loads(result.stdout)
        for asset in release["assets"]:
            if asset["name"] == Path(dmg).name:
                digest = "sha256:" + hashlib.sha256(Path(dmg).read_bytes()).hexdigest()
                if asset.get("digest") != digest:
                    raise RuntimeError("Existing immutable archive has a different or unverifiable digest")
                archive_exists = True
        if any(asset["name"] == "appcast.xml" for asset in release["assets"]):
            with tempfile.TemporaryDirectory() as directory:
                gh("release", "download", "nightly", "--repo", repository, "--pattern", "appcast.xml", "--dir", directory)
                version = ET.parse(Path(directory) / "appcast.xml").findtext(".//{http://www.andymatuschak.org/xml-namespaces/sparkle}version")
                if tuple(map(int, version.split("."))) >= tuple(map(int, info["YOYO_BUILD_VERSION"].split("."))):
                    raise RuntimeError("Refusing to replace an equal or newer nightly update")
        gh("api", "--method", "PATCH", f"repos/{repository}/git/refs/tags/nightly",
           "-f", f"sha={os.environ['GITHUB_SHA']}", "-F", "force=true")
    # Never overwrite or delete versioned archives: cached feeds still refer to them.
    if not archive_exists:
        gh("release", "upload", tag, dmg, "--repo", repository)
    gh("release", "upload", tag, "artifacts/appcast.xml", "--repo", repository, "--clobber")


if __name__ == "__main__":
    main()
