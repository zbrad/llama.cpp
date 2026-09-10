"""Verify local GGUF model files against their source HuggingFace repo.

Multi-shard GGUF splits are not size-balanced -- the first shard of a split
can legitimately be a few MB while later shards are tens of GB -- and
`file(1)` does not recognize GGUF, so its format guess on quantized tensor
bytes is meaningless. Neither is a valid corruption signal (see
~/.claude/projects/github-com-zbrad-llama-cpp/memory/gguf_shard_verification.md
for the incident that prompted this). The only authoritative reference is
the size and LFS sha256 the source repo itself has on record.

Usage:
    python3 tuned/gguf_shard_verifier.py <repo_id> <local_file_or_dir>
    python3 tuned/gguf_shard_verifier.py <repo_id> <local_file> --hash
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from huggingface_hub import HfApi
from huggingface_hub.errors import RepositoryNotFoundError
from huggingface_hub.hf_api import RepoSibling

logger = logging.getLogger(__name__)

_HASH_CHUNK_BYTES = 8 * 1024 * 1024


@dataclass
class ShardVerificationResult:
    """Outcome of comparing one local file to its HuggingFace repo record."""

    rfilename: str
    local_path: Path
    expected_size: Optional[int]
    actual_size: Optional[int]
    expected_sha256: Optional[str]
    actual_sha256: Optional[str]
    status: str

    @property
    def ok(self) -> bool:
        """Whether this file is fine: verified, or simply not part of this repo."""
        return self.status in ("ok", "not_in_repo")


class GgufShardVerifier:
    """Check local GGUF files against a HuggingFace model repo's own metadata.

    Never trusts `file(1)`'s format guess or comparisons between sibling
    shard sizes -- only the size and LFS sha256 the repo itself declares.
    """

    def __init__(self, repo_id: str) -> None:
        """Initialize against one HuggingFace model repo.

        Args:
            repo_id: e.g. "unsloth/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF".
        """
        self._repo_id = repo_id
        self._api = HfApi()
        self._siblings: Optional[list[RepoSibling]] = None

    def verify_path(
        self,
        local_path: Path,
        *,
        rfilename: Optional[str] = None,
        check_hash: bool = False,
    ) -> ShardVerificationResult:
        """Verify one local file against its record in the repo.

        Args:
            local_path: file on disk to check.
            rfilename: exact path within the repo. If omitted, resolved by
                matching local_path's file name against the repo's file list.
            check_hash: also compare sha256 -- reads the whole file, slow
                for multi-GB shards. Size alone already catches truncation.

        Returns:
            The verification outcome; never raises for an ordinary mismatch.
        """
        actual_size = local_path.stat().st_size if local_path.exists() else None
        sibling = self._find_sibling(local_path, rfilename)
        if sibling is None:
            return ShardVerificationResult(
                rfilename=rfilename or local_path.name,
                local_path=local_path,
                expected_size=None,
                actual_size=actual_size,
                expected_sha256=None,
                actual_sha256=None,
                status="not_in_repo",
            )
        if actual_size is None:
            return ShardVerificationResult(
                rfilename=sibling.rfilename,
                local_path=local_path,
                expected_size=sibling.size,
                actual_size=None,
                expected_sha256=None,
                actual_sha256=None,
                status="missing_local",
            )

        expected_sha256 = sibling.lfs.sha256 if sibling.lfs is not None else None
        if actual_size != sibling.size:
            return ShardVerificationResult(
                rfilename=sibling.rfilename,
                local_path=local_path,
                expected_size=sibling.size,
                actual_size=actual_size,
                expected_sha256=expected_sha256,
                actual_sha256=None,
                status="size_mismatch",
            )

        actual_sha256: Optional[str] = None
        if check_hash and expected_sha256 is not None:
            actual_sha256 = self._local_sha256(local_path)
            if actual_sha256 != expected_sha256:
                return ShardVerificationResult(
                    rfilename=sibling.rfilename,
                    local_path=local_path,
                    expected_size=sibling.size,
                    actual_size=actual_size,
                    expected_sha256=expected_sha256,
                    actual_sha256=actual_sha256,
                    status="hash_mismatch",
                )

        return ShardVerificationResult(
            rfilename=sibling.rfilename,
            local_path=local_path,
            expected_size=sibling.size,
            actual_size=actual_size,
            expected_sha256=expected_sha256,
            actual_sha256=actual_sha256,
            status="ok",
        )

    def _find_sibling(
        self, local_path: Path, rfilename: Optional[str]
    ) -> Optional[RepoSibling]:
        """Look up this file's record in the repo's file listing."""
        siblings = self._load_siblings()
        if rfilename is not None:
            for sibling in siblings:
                if sibling.rfilename == rfilename:
                    return sibling
            return None

        matches = [s for s in siblings if Path(s.rfilename).name == local_path.name]
        if len(matches) > 1:
            logger.warning(
                "%s matches multiple files in %s; using the first (%s)",
                local_path.name,
                self._repo_id,
                matches[0].rfilename,
            )
        return matches[0] if matches else None

    def _load_siblings(self) -> list[RepoSibling]:
        """Fetch and cache the repo's file listing with size/hash metadata."""
        if self._siblings is None:
            try:
                info = self._api.model_info(self._repo_id, files_metadata=True)
            except RepositoryNotFoundError as exc:
                raise ValueError(f"no such repo: {self._repo_id}") from exc
            self._siblings = list(info.siblings)
        return self._siblings

    @staticmethod
    def _local_sha256(path: Path) -> str:
        """Compute a local file's sha256, streaming so multi-GB shards don't load into memory."""
        hasher = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(_HASH_CHUNK_BYTES), b""):
                hasher.update(chunk)
        return hasher.hexdigest()

    @staticmethod
    def _resolve_local_paths(local_path: Path) -> list[Path]:
        """Expand a file or directory argument into the *.gguf files to check."""
        if local_path.is_file():
            return [local_path]
        if local_path.is_dir():
            return sorted(local_path.glob("*.gguf"))
        raise ValueError(f"no such file or directory: {local_path}")

    @staticmethod
    def _format_result(result: ShardVerificationResult) -> str:
        """Render one result as a single human-readable line."""
        if result.status == "ok":
            hash_note = " +hash" if result.actual_sha256 is not None else ""
            return f"OK    {result.rfilename} ({result.actual_size:,} bytes{hash_note})"
        if result.status == "not_in_repo":
            return f"SKIP  {result.local_path.name}: not found in repo"
        if result.status == "missing_local":
            return f"FAIL  {result.rfilename}: local file does not exist"
        if result.status == "size_mismatch":
            return (
                f"FAIL  {result.rfilename}: size mismatch "
                f"(expected {result.expected_size:,}, got {result.actual_size:,})"
            )
        if result.status == "hash_mismatch":
            return (
                f"FAIL  {result.rfilename}: sha256 mismatch "
                f"(expected {result.expected_sha256}, got {result.actual_sha256})"
            )
        raise ValueError(f"unknown verification status: {result.status}")

    @classmethod
    def main(cls, argv: Optional[list[str]] = None) -> int:
        """CLI entry point. Returns a process exit code."""
        logging.basicConfig(level=logging.INFO, format="%(message)s")

        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("repo_id", help="HuggingFace model repo, e.g. org/name")
        parser.add_argument(
            "local_path", type=Path, help="a .gguf file, or a directory of them"
        )
        parser.add_argument(
            "--rfilename",
            default=None,
            help="exact path within the repo (only valid with a single local file)",
        )
        parser.add_argument(
            "--hash",
            action="store_true",
            help="also verify sha256 (reads the whole file; slow for multi-GB shards)",
        )
        args = parser.parse_args(argv)

        verifier = cls(args.repo_id)
        try:
            local_paths = verifier._resolve_local_paths(args.local_path)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        if args.rfilename is not None and len(local_paths) != 1:
            print(
                "error: --rfilename requires a single local file, not a directory",
                file=sys.stderr,
            )
            return 2

        all_ok = True
        try:
            for local_path in local_paths:
                result = verifier.verify_path(
                    local_path, rfilename=args.rfilename, check_hash=args.hash
                )
                print(verifier._format_result(result))
                all_ok = all_ok and result.ok
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

        return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(GgufShardVerifier.main())
