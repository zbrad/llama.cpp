# tuned/ — GPU-tuned llama.cpp builds

Per-variant builds of llama.cpp (`gb10`; `rtx40` and `rtx50` are defined in `common-data/` but not yet built from
this repo) against one CUDA toolkit. Every script takes the variant as its argument and sources `env.sh`, which
selects the toolkit (`CUDA_TAG=cu134` or `CUDA_VER=13.4`) and refuses to guess one.

## Prerequisites

- **The web UI.** `build.sh` stops unless `tools/ui/dist/index.html` exists: extract the `ui/` tree of a
  [llama-ui-tuned](https://github.com/zbrad/llama-ui-tuned) tarball there. Without it, upstream's CMake would run
  `npm ci` on upstream's lockfile or download a UI. `check-ui.sh <build-dir>` verifies the UI embedded in a build is
  that tarball's and was built from this checkout's `tools/ui` sources.
- **NCCL.** `nccl.pins` pins a `zbrad/nccl` release per variant and toolkit (linked statically). A toolkit with no pin
  uses the system `libnccl2` named by the toolkit's `TOOLKIT_NCCL_VERSION`, bundled by `package.sh`. A toolkit
  that declares no NCCL and has no pin cannot be built. Move a pin deliberately, in its own commit.
- **Network access** for the full test (ctest `model` tests fetch small models from Hugging Face; `HF_TOKEN` may help
  with rate limits) and for the smoke test (a ~1 MB model).

## Flow

Stages run in this order; each gate in the later stages refuses to run on a stale earlier stage.

| Stage | Command | Output |
|-------|---------|--------|
| 1. build | `CUDA_TAG=cu134 bash tuned/build.sh gb10` | `tuned/build/<cuda>/cmake/`. Never the repo-root `build/` the local units run. Allocates the release label and compiles it into `llama-server --version` |
| 2. full test | `bash tuned/full_test.sh gb10` | `tuned/build/<cuda>/releases/TEST_RESULTS_gb10.log`, ending in `Full test suite summary` (the whole ctest suite) |
| 3. package | `bash tuned/package.sh gb10` | `tuned/build/<cuda>/dist/` tarball, `.sha256`, `package-info.txt`. Refuses a build from source other than HEAD. Writes a DRAFT `tuned/releases/RELEASE_NOTES_<label>.md` if none exists |
| 4. smoke test | `bash tuned/smoke_test.sh gb10` | `tuned/build/<cuda>/releases/SMOKE_RESULTS_gb10.log`. Runs `install.sh` on the local tarball into a scratch directory and uses the result; nothing is published |
| 5. notes | edit `tuned/releases/RELEASE_NOTES_<label>.md`, delete its DRAFT line, commit it | a tracked, reviewed notes file |
| 6. release | `bash tuned/release.sh gb10 [--publish]` | Dry run by default: every gate really runs, nothing is published. With `--publish`, creates the GitHub release |

The later stages read `CUDA_TAG` / `CUDA_VER` the same way; set it for each command.

`release.sh` gates: clean tree, branch, origin, `gh`, toolkit, tag free; a passing test log newer than the build (or a
`relabel.json`, below); a package made from that build after the tests; a passing smoke log newer than the tarball;
only release notes changed since the package's commit; notes not a DRAFT.

## Identity

One identity per release: the date label `package.sh` allocates (UTC date of HEAD's commit plus a sequence for that
date, always written), as the tag `v0.<YYYYMMDD>.<seq>-<variant>-<cuda>`, e.g. `v0.20261019.0-gb10-cu134`. The tarball
is `llama-cpp-0.<YYYYMMDD>.<seq>-<variant>-<cuda>.tar.gz`. `gh` creates the tag on the `tuned-builds` head, and
`install.sh` fetches `llmsrv.sh` and `models/aliases.json` from it, so there is no separate source tag and no pin to
bump. The build number `llama-server --version` also prints is not the release identity.

## Other files

- `relabel.sh <variant>`: gives a tested build a new release label without rerunning the suite, when the label it carries
  was taken meanwhile. Rebuilds, compares every ELF section with `elf_section_diff.py` (only the label bytes and derived
  sections such as the build id may differ), and writes `relabel.json`, which `release.sh` accepts in place of a log newer
  than the build. On a refusal, run `full_test.sh`.
- `compat-notes.sh`: prints the "CUDA / driver compatibility" section of the release notes; `package.sh` runs it.
  `tested-drivers.txt` lists the drivers a release has actually been run on.
- `llmsrv.sh`, `models.ini`: the systemd `--user` launcher and router-mode presets shipped with a release. See
  [docs/gb10/llmsrv-launcher.md](../docs/gb10/llmsrv-launcher.md).
- `gguf_shard_verifier.py`, `fixtures/`: GGUF integrity check against the source Hugging Face repo, and generators for
  the synthetic `nemotron_h_moe` fixtures used by the ollama-compat tests.
- `tests/`: pytest tests for the tooling (`python -m pytest tuned/tests`).
- `common-data/`, `common.sh`, `common.sh.sha`: vendored from tuned-common; refresh with `sync-common.sh check|sync`,
  do not hand-edit.
- `repo.env`: llama.cpp's own CMake flags (`GGML_CUDA_*`, `LLAMA_OPENSSL=ON`, ...). It may add settings but not change a
  shared key.
- `compliance.conf`: read by tuned-common's `tools/tuned_compliance.sh`; records attestations, exceptions and n/a
  against its `docs/ARCHITECTURE.md`.

Everything a build makes lives in `tuned/build/<cuda>/` (ignored by git): `cmake/`, `ccache/`, `dist/`, `releases/`.
Maintainer notes on the release process are in [docs/gb10/release.md](../docs/gb10/release.md); layout and naming
rules are in tuned-common's `docs/ARCHITECTURE.md`.
