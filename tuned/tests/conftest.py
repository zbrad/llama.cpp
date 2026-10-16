"""Fixtures for the tuned/ tool tests: a compiler for tiny shared libraries."""

import shutil
import subprocess
from pathlib import Path
from typing import Callable

import pytest


@pytest.fixture
def build_lib(tmp_path: Path) -> Callable[[str, str, str], Path]:
    """Return a function that compiles C source into a shared library.

    Args:
        tmp_path: pytest's per-test directory.

    Returns:
        A callable (directory name, file name, C source) -> path of the library.
    """
    if shutil.which("gcc") is None:
        pytest.skip("gcc is not installed")

    def _build(directory: str, name: str, source: str) -> Path:
        out_dir = tmp_path / directory
        out_dir.mkdir(exist_ok=True)
        src = out_dir / f"{name}.c"
        src.write_text(source, encoding="utf-8")
        lib = out_dir / f"lib{name}.so"
        subprocess.run(
            ["gcc", "-shared", "-fPIC", "-O1", "-o", str(lib), str(src)], check=True
        )
        return lib

    return _build
