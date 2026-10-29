"""Assemble verified per-profile artifacts and render versioned release notes."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import stat
import zipfile
import re
import shutil
import subprocess
from pathlib import Path


def project_root(start: Path) -> Path:
    for candidate in (start, *start.parents):
        if (candidate / "build.zig.zon").is_file():
            return candidate
    raise ValueError("build.zig.zon not found")


def package_version(root: Path) -> str:
    match = re.search(
        r'^\s*\.version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
        (root / "build.zig.zon").read_text(),
        re.MULTILINE,
    )
    if match is None:
        raise ValueError("a stable package version is required")
    return match[1]


def release_notes(root: Path, version: str, repository: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or any(
        part in (".", "..") for part in repository.split("/")
    ):
        raise ValueError("invalid repository name")
    notes = root / f"docs/releases/v{version}.md"

    def absolute_link(match: re.Match[str]) -> str:
        target = match[1]
        if "://" in target or target.startswith("#"):
            return match[0]
        path, separator, fragment = target.partition("#")
        resolved = (notes.parent / path).resolve()
        if not resolved.is_file():
            raise ValueError(f"release note target is missing: {path}")
        relative = resolved.relative_to(root.resolve()).as_posix()
        return f"](https://github.com/{repository}/blob/v{version}/{relative}{separator}{fragment})"

    return re.sub(r"\]\(([^)]+)\)", absolute_link, notes.read_text())


def package_zip(root: Path, binary: Path, output: Path, version: str, repository: str) -> Path:
    """Wrap an already verified source-build artifact for Moonraker's ZIP updater."""
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("invalid package version")
    if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
            or any(part in (".", "..") for part in repository.split("/"))):
        raise ValueError("invalid repository name")
    if not re.fullmatch(rf"phobos-v{re.escape(version)}-[A-Za-z0-9_.+-]+", binary.name):
        raise ValueError("invalid binary asset name")
    owner, project = repository.split("/")
    name = "phobos-" + binary.name.removeprefix(f"phobos-v{version}-") + ".zip"
    metadata = {"project_owner": owner, "project_name": project, "version": "v" + version, "asset_name": name}
    destination = output / name
    entries = {
        "phobos": (binary.read_bytes(), 0o755),
        "release_info.json": ((json.dumps(metadata, indent=2) + "\n").encode(), 0o644),
        ".version": (("v" + version + "\n").encode(), 0o644),
        "LICENSE": ((root / "LICENSE").read_bytes(), 0o644),
    }
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, (content, mode) in entries.items():
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, content)
    return destination


def assemble(root: Path, source: Path, output: Path, repository: str) -> None:
    if not output.resolve().is_relative_to((root / ".scratch").resolve()):
        raise ValueError("output must be inside project .scratch")
    version = package_version(root)
    notes = release_notes(root, version, repository)
    # The existing build helper owns the profile list; no shell command is constructed.
    profiles = subprocess.check_output(
        [str(root / "scripts/build-release.sh"), "--list"], text=True
    ).splitlines()
    if not profiles or len(profiles) != len(set(profiles)):
        raise ValueError("invalid build profile list")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("output must be empty")
    checksums = []
    metadata = []
    seen = set()
    for profile in profiles:
        directory = source / f"release-{profile}"
        with (directory / "profiles.tsv").open() as stream:
            entries = list(csv.DictReader(stream, delimiter="\t"))
        if len(entries) != 1 or entries[0].get("profile") != profile:
            raise ValueError(f"incorrect profile metadata: {profile}")
        entry = entries[0]
        asset = entry["asset"]
        if (
            not re.fullmatch(rf"phobos-v{re.escape(version)}-[A-Za-z0-9_.+-]+", asset)
            or asset in seen
        ):
            raise ValueError(f"invalid or duplicate asset: {asset}")
        seen.add(asset)
        match = re.fullmatch(
            r"([0-9a-f]{64})  " + re.escape(asset) + r"\n?",
            (directory / "SHA256SUMS").read_text(),
        )
        with (directory / asset).open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if match is None or match[1] != actual:
            raise ValueError(f"asset checksum mismatch: {profile}")
        shutil.copyfile(directory / asset, output / asset)
        checksums.append(f"{actual}  {asset}\n")
        zipped = package_zip(root, output / asset, output, version, repository)
        with zipped.open("rb") as stream:
            zipped_hash = hashlib.file_digest(stream, "sha256").hexdigest()
        checksums.append(f"{zipped_hash}  {zipped.name}\n")
        metadata.append(entry)
    (output / "SHA256SUMS").write_text("".join(checksums))
    with (output / "profiles.tsv").open("w") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=["profile", "target", "cpu", "c_softfp", "asset"],
            delimiter="\t",
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(metadata)
    (output / "release-notes.md").write_text(notes)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository", default="maci0/phobos")
    args = parser.parse_args()
    assemble(
        project_root(Path(__file__).resolve()), args.input, args.output, args.repository
    )


if __name__ == "__main__":
    main()
