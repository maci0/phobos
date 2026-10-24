import hashlib
import shutil
import subprocess
from pathlib import Path

import pytest

from tools.release import prepare


@pytest.mark.parametrize(
    ("target", "cpu", "failure"),
    [
        ("mipsel-linux-musleabihf", "mips32r5+fp64+nan2008", None),
        ("mipsel-linux-musleabihf", "mips32r5+fp64", "expected NaN2008"),
        ("mipsel-linux-musleabi", "mips32r5+soft_float+nan2008", "expected FP64"),
        ("mipsel-linux-musleabihf", "mips32r2+fp64+nan2008", "expected MIPS32r5"),
        ("mipsel-linux-musleabihf", "mips32r5+fp64+nan2008+msa", "unexpected MIPS"),
        ("mips-linux-musleabihf", "mips32r5+fp64+nan2008", "incorrect ELF byte order"),
    ],
)
def test_ad5x_profile_checks_real_elf_abi(
    tmp_path: Path, target: str, cpu: str, failure: str | None
) -> None:
    root = prepare.project_root(Path(__file__).resolve())
    zig = shutil.which("zig")
    assert zig is not None, "Zig is required to check release ELF validation"
    source = root / "tests/fixtures/mips_elf_probe.c"
    asset = f"phobos-v{prepare.package_version(root)}-mipsel-linux-musleabihf"
    binary = tmp_path / asset
    subprocess.run(
        [
            zig,
            "cc",
            "-target",
            target,
            f"-mcpu={cpu}",
            "-static",
            "-nostdlib",
            "-Wl,-e,_start",
            str(source),
            "-o",
            str(binary),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    )
    checksum = hashlib.sha256(binary.read_bytes()).hexdigest()
    (tmp_path / "SHA256SUMS").write_text(f"{checksum}  {asset}\n")
    result = subprocess.run(
        [
            str(root / "scripts/build-release.sh"),
            "--verify-only",
            "--output",
            str(tmp_path),
            "ad5x-mipsel",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if failure is None:
        assert result.returncode == 0, result.stderr
        assert f"verified {asset}" in result.stdout
        assert f"{asset}: OK" in result.stdout
    else:
        assert result.returncode != 0
        assert failure in result.stderr
