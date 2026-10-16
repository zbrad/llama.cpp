"""Prove that two builds of the same binaries differ only in a label.

tuned/relabel.sh rebuilds a tested build with a new release label. The label is
compiled into a fixed-width buffer (LLAMA_TUNED_RELEASE in common/build-info.cpp.in),
so a rebuild that changes only the label leaves every ELF section the same size and
every byte the same except inside that buffer. This module records a per-section
snapshot of a directory of ELF files and compares two snapshots; anything else that
moved, resized or changed is reported, and the caller then runs the full test suite.

ELF64 little-endian only (every target here). The struct formats are little-endian
('<') on purpose: this reads the ELF layout, it is not a codec and defines no format.
No source port: written for tuned-builds, not converted from C++.
"""

import hashlib
import json
import logging
import struct
import sys
from pathlib import Path
from typing import Optional, TypeAlias

logger = logging.getLogger(__name__)

SHT_NULL = 0
SHT_SYMTAB = 2
SHT_NOBITS = 8
SHT_DYNSYM = 11

# Sections whose content is derived from the rest of the file (the build id is a hash of
# the linked output), so they differ whenever anything else does and prove nothing alone.
DERIVED_SECTIONS = frozenset({".note.gnu.build-id"})

SectionTable: TypeAlias = dict[str, dict[str, object]]
Snapshot: TypeAlias = dict[str, dict[str, object]]


class ElfSectionDiff:
    """Snapshot and compare the sections of a directory of ELF files.

    A snapshot maps each file name to its sections (size and sha256) and, if the file
    defines the label symbol, to the symbol's section, offset, size and value. For the
    section holding the symbol the sha256 is taken with the symbol's bytes zeroed, so two
    builds that differ only in the label have equal snapshots except for the value.
    """

    def __init__(self, symbol: str) -> None:
        """Create a differ for one label symbol.

        Args:
            symbol: Name of the fixed-width label buffer (e.g. LLAMA_TUNED_RELEASE).
        """
        if not symbol or not symbol.replace("_", "").isalnum():
            raise ValueError(f"not a symbol name: {symbol!r}")
        self._symbol = symbol

    def snapshot_dir(self, directory: Path) -> Snapshot:
        """Snapshot every regular ELF file in a directory (symlinks are skipped).

        Args:
            directory: Directory holding the build's binaries and libraries.

        Returns:
            File name to {"sections": {...}, "symbol": {...} or None}.
        """
        result: Snapshot = {}
        for path in sorted(directory.iterdir()):
            if path.is_symlink() or not path.is_file():
                continue
            data = path.read_bytes()
            if data[:4] != b"\x7fELF":
                continue
            result[path.name] = self._snapshot_file(path.name, data)
        if not result:
            raise ValueError(f"no ELF files in {directory}")
        return result

    def compare(
        self, before: Snapshot, after: Snapshot, expect_label: Optional[str] = None
    ) -> list[str]:
        """List every difference that is more than the label.

        Args:
            before: Snapshot of the tested build.
            after: Snapshot of the relabelled build.
            expect_label: If given, every file that carries the symbol must hold it.

        Returns:
            Human-readable reasons; empty means the builds differ only in the label
            (and in derived sections such as the build id).
        """
        problems: list[str] = []
        if set(before) != set(after):
            only_before = sorted(set(before) - set(after))
            only_after = sorted(set(after) - set(before))
            problems.append(f"file sets differ: -{only_before} +{only_after}")
        for name in sorted(set(before) & set(after)):
            problems.extend(self._compare_file(name, before[name], after[name]))
            sym = after[name].get("symbol")
            if expect_label is not None and isinstance(sym, dict):
                if sym.get("value") != expect_label:
                    problems.append(
                        f"{name}: {self._symbol} holds {sym.get('value')!r}, "
                        f"expected {expect_label!r}"
                    )
        return problems

    @classmethod
    def main(cls, argv: list[str]) -> int:
        """Command line: snapshot <dir> <out.json> | compare <before> <after> [label].

        Args:
            argv: Arguments after the program name.

        Returns:
            0 when the builds differ only in the label (or the snapshot was written).
        """
        symbol = "LLAMA_TUNED_RELEASE"
        if len(argv) == 3 and argv[0] == "snapshot":
            snap = cls(symbol).snapshot_dir(Path(argv[1]))
            Path(argv[2]).write_text(json.dumps(snap, sort_keys=True), encoding="utf-8")
            print(f"snapshot: {len(snap)} ELF files -> {argv[2]}")
            return 0
        if len(argv) in (3, 4) and argv[0] == "compare":
            before = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
            after = json.loads(Path(argv[2]).read_text(encoding="utf-8"))
            label = argv[3] if len(argv) == 4 else None
            problems = cls(symbol).compare(before, after, label)
            for problem in problems:
                print(f"DIFFERS: {problem}")
            if not problems:
                print(f"label-only: {len(after)} ELF files differ only in {symbol}")
            return 1 if problems else 0
        print("usage: elf_section_diff.py snapshot <dir> <out.json>", file=sys.stderr)
        print(
            "       elf_section_diff.py compare <before> <after> [label]",
            file=sys.stderr,
        )
        return 2

    def _compare_file(
        self, name: str, before: dict[str, object], after: dict[str, object]
    ) -> list[str]:
        """Compare one file's two snapshots."""
        problems: list[str] = []
        b_sec = before["sections"]
        a_sec = after["sections"]
        assert isinstance(b_sec, dict) and isinstance(a_sec, dict)
        if list(b_sec) != list(a_sec):
            problems.append(f"{name}: section list differs")
            return problems
        for sec, b_info in b_sec.items():
            a_info = a_sec[sec]
            if sec in DERIVED_SECTIONS:
                continue
            if b_info["size"] != a_info["size"]:
                problems.append(f"{name}: section {sec} resized")
            elif b_info["sha256"] != a_info["sha256"]:
                problems.append(f"{name}: section {sec} changed")
        b_sym, a_sym = before.get("symbol"), after.get("symbol")
        if (b_sym is None) != (a_sym is None):
            problems.append(f"{name}: {self._symbol} present in only one build")
        elif isinstance(b_sym, dict) and isinstance(a_sym, dict):
            for key in ("section", "offset", "size"):
                if b_sym[key] != a_sym[key]:
                    problems.append(f"{name}: {self._symbol} moved ({key})")
        return problems

    def _snapshot_file(self, name: str, data: bytes) -> dict[str, object]:
        """Parse the section headers of one ELF64 file and hash each section."""
        if data[4] != 2 or data[5] != 1:
            raise ValueError(f"{name}: not a little-endian ELF64 file")
        (shoff,) = struct.unpack_from("<Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        headers = [
            struct.unpack_from("<IIQQQQII", data, shoff + i * shentsize)
            for i in range(shnum)
        ]
        names = self._section_names(data, headers, shstrndx)
        symbol = self._find_symbol(data, headers, names)
        sections: SectionTable = {}
        for index, header in enumerate(headers):
            _, typ, _, _, offset, size, _, _ = header
            if typ in (SHT_NULL, SHT_NOBITS):
                continue
            content = bytearray(data[offset : offset + size])
            if symbol is not None and symbol["index"] == index:
                start = int(symbol["offset"]) - offset  # type: ignore[arg-type]
                content[start : start + int(symbol["size"])] = bytes(int(symbol["size"]))  # type: ignore[arg-type]
            sections[names[index]] = {
                "size": size,
                "sha256": hashlib.sha256(bytes(content)).hexdigest(),
            }
        info: Optional[dict[str, object]] = None
        if symbol is not None:
            start = int(symbol["offset"])  # type: ignore[arg-type]
            raw = data[start : start + int(symbol["size"])]  # type: ignore[arg-type]
            info = {
                "section": names[int(symbol["index"])],  # type: ignore[arg-type]
                "offset": symbol["offset"] - headers[int(symbol["index"])][4],  # type: ignore[operator, arg-type]
                "size": symbol["size"],
                "value": raw.split(b"\0", 1)[0].decode("utf-8", "replace"),
            }
        return {"sections": sections, "symbol": info}

    @staticmethod
    def _section_names(
        data: bytes, headers: list[tuple[int, ...]], shstrndx: int
    ) -> list[str]:
        """Resolve every section's name from the section-header string table."""
        stroff = headers[shstrndx][4]
        result: list[str] = []
        for header in headers:
            start = stroff + header[0]
            end = data.index(b"\0", start)
            result.append(data[start:end].decode("ascii", "replace"))
        return result

    def _find_symbol(
        self, data: bytes, headers: list[tuple[int, ...]], names: list[str]
    ) -> Optional[dict[str, object]]:
        """Find the label symbol in .symtab or .dynsym: section index, file offset, size."""
        for table in headers:
            if table[1] not in (SHT_SYMTAB, SHT_DYNSYM):
                continue
            strtab = headers[table[6]]
            for pos in range(table[4], table[4] + table[5], 24):
                st_name, _, _, shndx, value, size = struct.unpack_from(
                    "<IBBHQQ", data, pos
                )
                start = strtab[4] + st_name
                if data[start : data.index(b"\0", start)] != self._symbol.encode():
                    continue
                if shndx == 0 or shndx >= len(headers):
                    continue
                section = headers[shndx]
                return {
                    "index": shndx,
                    "offset": section[4] + (value - section[3]),
                    "size": size,
                }
        return None


if __name__ == "__main__":
    sys.exit(ElfSectionDiff.main(sys.argv[1:]))
