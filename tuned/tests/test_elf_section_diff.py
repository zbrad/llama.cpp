"""Tests for tuned/elf_section_diff.py (label-only build comparison)."""

import json
import sys
from pathlib import Path
from typing import Callable

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from elf_section_diff import ElfSectionDiff  # noqa: E402

BuildLib = Callable[[str, str, str], Path]


def _src(label: str, size: int = 64, body: str = "return 7;") -> str:
    return (
        f'char LLAMA_TUNED_RELEASE[{size}] = "{label}";\n'
        f"int answer(void) {{ {body} }}\n"
        "const char * release(void) { return LLAMA_TUNED_RELEASE; }\n"
    )


def _snap(directory: Path) -> dict:
    return ElfSectionDiff("LLAMA_TUNED_RELEASE").snapshot_dir(directory)


def test_compare_label_only_change_is_clean(build_lib: BuildLib) -> None:
    a = build_lib("a", "x", _src("v0.20261016.0-gb10-cu133"))
    b = build_lib("b", "x", _src("v0.20261016.1-gb10-cu133"))
    problems = ElfSectionDiff("LLAMA_TUNED_RELEASE").compare(
        _snap(a.parent), _snap(b.parent), "v0.20261016.1-gb10-cu133"
    )
    assert problems == [], problems


def test_snapshot_reads_the_label_value(build_lib: BuildLib) -> None:
    a = build_lib("a", "x", _src("v0.20261016.0-gb10-cu133"))
    snap = _snap(a.parent)
    assert snap["libx.so"]["symbol"]["value"] == "v0.20261016.0-gb10-cu133"
    assert snap["libx.so"]["symbol"]["size"] == 64


def test_compare_code_change_is_reported(build_lib: BuildLib) -> None:
    a = build_lib("a", "x", _src("v0.20261016.0-gb10-cu133"))
    b = build_lib("b", "x", _src("v0.20261016.1-gb10-cu133", body="return 8;"))
    problems = ElfSectionDiff("LLAMA_TUNED_RELEASE").compare(_snap(a.parent), _snap(b.parent))
    assert any(".text" in p for p in problems), problems


def test_compare_resized_buffer_is_reported(build_lib: BuildLib) -> None:
    a = build_lib("a", "x", _src("v0.20261016.0-gb10-cu133", size=64))
    b = build_lib("b", "x", _src("v0.20261016.1-gb10-cu133", size=128))
    problems = ElfSectionDiff("LLAMA_TUNED_RELEASE").compare(_snap(a.parent), _snap(b.parent))
    assert any("moved" in p or "resized" in p or "changed" in p for p in problems), problems


def test_compare_wrong_expected_label_is_reported(build_lib: BuildLib) -> None:
    a = build_lib("a", "x", _src("v0.20261016.0-gb10-cu133"))
    b = build_lib("b", "x", _src("v0.20261016.1-gb10-cu133"))
    problems = ElfSectionDiff("LLAMA_TUNED_RELEASE").compare(
        _snap(a.parent), _snap(b.parent), "v0.20261016.2-gb10-cu133"
    )
    assert any("expected" in p for p in problems), problems


def test_compare_unlabelled_file_must_be_identical(build_lib: BuildLib) -> None:
    plain = "int other(void) { return 1; }\n"
    a = build_lib("a", "y", plain)
    b = build_lib("b", "y", plain.replace("1", "2"))
    problems = ElfSectionDiff("LLAMA_TUNED_RELEASE").compare(_snap(a.parent), _snap(b.parent))
    assert problems, "a code change in a file without the label must be reported"


def test_compare_identical_builds_are_clean(build_lib: BuildLib) -> None:
    a = build_lib("a", "x", _src("v0.20261016.0-gb10-cu133"))
    b = build_lib("b", "x", _src("v0.20261016.0-gb10-cu133"))
    assert ElfSectionDiff("LLAMA_TUNED_RELEASE").compare(_snap(a.parent), _snap(b.parent)) == []


def test_snapshot_round_trips_through_json(build_lib: BuildLib) -> None:
    a = build_lib("a", "x", _src("v0.20261016.0-gb10-cu133"))
    snap = _snap(a.parent)
    assert json.loads(json.dumps(snap)) == snap


def test_compare_missing_file_is_reported(build_lib: BuildLib) -> None:
    a = build_lib("a", "x", _src("v0.20261016.0-gb10-cu133"))
    b = build_lib("b", "z", _src("v0.20261016.0-gb10-cu133"))
    problems = ElfSectionDiff("LLAMA_TUNED_RELEASE").compare(_snap(a.parent), _snap(b.parent))
    assert any("file sets differ" in p for p in problems), problems


def test_snapshot_dir_without_elf_files_raises(tmp_path: Path) -> None:
    (tmp_path / "note.txt").write_text("hello", encoding="utf-8")
    with pytest.raises(ValueError):
        ElfSectionDiff("LLAMA_TUNED_RELEASE").snapshot_dir(tmp_path)


def test_bad_symbol_name_raises() -> None:
    with pytest.raises(ValueError):
        ElfSectionDiff("not a symbol")
