import hashlib
import json
import zipfile
import subprocess
from pathlib import Path

import pytest

from tools.release import prepare


def fixture_artifacts(tmp_path: Path) -> tuple[Path, Path]:
    root = prepare.project_root(Path(__file__).resolve())
    version = prepare.package_version(root)
    profiles = subprocess.check_output(
        [str(root / "scripts/build-release.sh"), "--list"], text=True
    ).splitlines()
    source = tmp_path / "input"
    for profile in profiles:
        directory = source / f"release-{profile}"
        directory.mkdir(parents=True)
        asset = f"phobos-v{version}-{profile}"
        payload = (profile + "\n").encode()
        (directory / asset).write_bytes(payload)
        checksum = hashlib.sha256(payload).hexdigest()
        (directory / "SHA256SUMS").write_text(f"{checksum}  {asset}\n")
        (directory / "profiles.tsv").write_text(
            "profile\ttarget\tcpu\tc_softfp\tasset\n"
            f"{profile}\tfixture-target\tfixture-cpu\tfalse\t{asset}\n"
        )
    return root, source


def test_assemble_copies_every_asset_and_combines_manifests(tmp_path: Path) -> None:
    root, source = fixture_artifacts(tmp_path)
    output = tmp_path / "output"
    prepare.assemble(root, source, output, "maci0/phobos")
    assert len((output / "SHA256SUMS").read_text().splitlines()) == 16
    assert len((output / "profiles.tsv").read_text().splitlines()) == 9
    version = prepare.package_version(root)
    assert (output / f"phobos-v{version}-armv7-soft").read_bytes() == b"armv7-soft\n"
    assert (output / f"phobos-v{version}-ad5x-mipsel").read_bytes() == b"ad5x-mipsel\n"
    assert (
        f"https://github.com/maci0/phobos/blob/v{version}/"
        in (output / "release-notes.md").read_text()
    )


def test_assemble_rejects_corrupt_or_missing_artifacts(tmp_path: Path) -> None:
    root, source = fixture_artifacts(tmp_path)
    checksum = source / "release-armv7-soft/SHA256SUMS"
    checksum.write_text("0" * 64 + "  wrong-name\n")
    with pytest.raises(ValueError, match="checksum mismatch"):
        prepare.assemble(root, source, tmp_path / "corrupt", "maci0/phobos")
    checksum.unlink()
    with pytest.raises(FileNotFoundError):
        prepare.assemble(root, source, tmp_path / "missing", "maci0/phobos")


@pytest.mark.parametrize(
    "asset", ["../escape", "phobos-v0.0.0-wrong", "file with spaces"]
)
def test_assemble_rejects_wrong_version_and_unsafe_names(
    tmp_path: Path, asset: str
) -> None:
    root, source = fixture_artifacts(tmp_path)
    metadata = source / "release-armv7-soft/profiles.tsv"
    lines = metadata.read_text().splitlines()
    fields = lines[1].split("\t")
    fields[-1] = asset
    metadata.write_text(lines[0] + "\n" + "\t".join(fields) + "\n")
    with pytest.raises(ValueError, match="invalid or duplicate asset"):
        prepare.assemble(root, source, tmp_path / "output", "maci0/phobos")


def test_assemble_refuses_old_output_and_wrong_profile(tmp_path: Path) -> None:
    root, source = fixture_artifacts(tmp_path)
    output = tmp_path / "output"
    output.mkdir()
    (output / "old").write_text("keep")
    with pytest.raises(ValueError, match="must be empty"):
        prepare.assemble(root, source, output, "maci0/phobos")
    assert (output / "old").read_text() == "keep"
    metadata = source / "release-armv7-soft/profiles.tsv"
    metadata.write_text(metadata.read_text().replace("armv7-soft\t", "wrong\t"))
    with pytest.raises(ValueError, match="incorrect profile metadata"):
        prepare.assemble(root, source, tmp_path / "wrong", "maci0/phobos")


def test_assemble_refuses_output_outside_scratch(tmp_path: Path) -> None:
    root, source = fixture_artifacts(tmp_path)
    with pytest.raises(ValueError, match="inside project .scratch"):
        prepare.assemble(root, source, root / "release-outside-scratch", "maci0/phobos")


def test_root_and_version_validation(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="not found"):
        prepare.project_root(Path("/nonexistent-phobos-root"))
    manifest = tmp_path / "build.zig.zon"
    manifest.write_text('.{ .version = "invalid" }')
    with pytest.raises(ValueError, match="stable package version"):
        prepare.package_version(tmp_path)
    manifest.write_text('.version = "1.2.3",\n')
    assert prepare.package_version(tmp_path) == "1.2.3"
    assert prepare.project_root(tmp_path / "nested/file") == tmp_path


def test_notes_reject_invalid_repository_and_missing_target(tmp_path: Path) -> None:
    root = prepare.project_root(Path(__file__).resolve())
    with pytest.raises(ValueError, match="repository name"):
        prepare.release_notes(root, "0.2.1", "../bad")
    notes = tmp_path / "docs/releases/v1.2.3.md"
    notes.parent.mkdir(parents=True)
    notes.write_text("[missing](../../missing.md)\n")
    with pytest.raises(ValueError, match="target is missing"):
        prepare.release_notes(tmp_path, "1.2.3", "maci0/phobos")


def test_zip_package_is_deterministic_executable_and_moonraker_compatible(tmp_path: Path) -> None:
    root = prepare.project_root(Path(__file__).resolve())
    version = prepare.package_version(root)
    binary = tmp_path / f"phobos-v{version}-arm-linux-musleabihf"
    binary.write_bytes(b"verified source-build fixture")
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()
    a = prepare.package_zip(root, binary, first, version, "maci0/phobos")
    b = prepare.package_zip(root, binary, second, version, "maci0/phobos")
    assert a.read_bytes() == b.read_bytes()
    with zipfile.ZipFile(a) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist()) == {"phobos", "release_info.json", ".version", "LICENSE"}
        assert archive.read("phobos") == binary.read_bytes()
        assert (archive.getinfo("phobos").external_attr >> 16) & 0o777 == 0o755
        assert json.loads(archive.read("release_info.json")) == {
            "project_owner": "maci0", "project_name": "phobos", "version": f"v{version}",
            "asset_name": "phobos-arm-linux-musleabihf.zip"
        }
        assert archive.read(".version") == f"v{version}\n".encode()
    with pytest.raises(FileExistsError):
        prepare.package_zip(root, binary, first, version, "maci0/phobos")
