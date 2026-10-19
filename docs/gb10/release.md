# Releasing a tuned build

How a tuned GB10 build of this fork is released. This is the maintainer
procedure; to just install a published build, see the Quick Start in
[README.md](README.md). `docs/release.md` in this repo is upstream's and does
not describe this process.

The flow is `tuned/build.sh`, `tuned/full_test.sh`, `tuned/package.sh`, `tuned/smoke_test.sh`, then
`tuned/release.sh`, then `tuned/publish.sh`, the same split as raft, cuvs and faiss. `release.sh` **never
publishes**: it runs every gate and, if all pass, writes a ready-marker. `publish.sh` publishes only from that marker.

## What a release is

One thing, with one identity: the binary release `v0.<YYYYMMDD>.<seq>-<variant>-<cuda>`
(e.g. `v0.20261016.0-gb10-cu133`). `install.sh` picks it by variant and CUDA version and fetches
`llmsrv.sh`, `models/aliases.json` and the chat templates from that same tag, which `gh` creates on
the `tuned-builds` head at release time, so they are exactly the files the release was made from.
zbrad/ollama's fetch script consumes the tarball. There is no separate source tag and no pin to bump.

The date is the UTC date of `HEAD`'s commit and `<seq>` is the lowest unused sequence for that date
among the repo's release tags (`0` for the first build of the day, written in full), both from
`gpu_tuned_allocate_date_label` in tuned-common (see its `docs/VERSIONING.md`). **`tuned/build.sh`
allocates the label** and compiles it into the binary: `llama-server --version` prints
`release: v0.20261016.0-gb10-cu133` above upstream's `version:` line. It is recorded in
`<build>/release-label`; `package.sh` and `release.sh` read it and never recompute it.
`GPU_TUNED_LABEL_SEQ=<n>` chooses the sequence without reading `origin`'s tags.

**The build number is not the identity.** `llama-server --version`'s `build N` is a commit count of this
fork's history (upstream's base count plus our own commits), so it rises with every commit here and is not
upstream's number. It is kept as `fork.commit_count` in the build info, for information only. Only
`--version` gains a line: `llama_build_info()`, the server's `system_fingerprint`, `/props`, the UI and the
User-Agent still read `b<N>-<sha>`, because upstream's tests expect a leading `b`. The change is five lines in
`common/build-info.cpp.in` and prints nothing extra when `LLAMA_TUNED_RELEASE` is unset.

Older release tags `v<build>-<variant>-<cuda>` (e.g. `v10931-gb10-cu133`) stay as they are; `install.sh`
accepts both shapes and prefers any date-label tag over a counter tag. The older source tags
`tuning-vN` exist and keep working, but nothing creates them any more.

## Build info

Every shipped `llama-server-tuned` and `libggml-cuda` carries one line of JSON in the ELF section
`.tuned_build_info`, and the tarball ships the same JSON as `BUILD_INFO.json` beside the binaries
(`install.sh` prints the release from it):

```bash
readelf -p .tuned_build_info llama-server-tuned | sed 's/^ *\[ *[0-9a-f]*\] *//' | jq .
# or, with tuned-common sourced:  gpu_tuned_read_build_info llama-server-tuned | jq .
```

It holds `release` (the identity, first), `component`, `variant`, `hardware`, `arch`, `cuda` (`tag`,
`version`, `nvcc`), `fork` (`url`, `commit` in full, `dirty`, `commit_count`), `upstream` (`url`, the declared
`ref` `upstream/master`, `base`, `nearest_tag`, `declared_version`), `deps.ui` (`name`, `tarball_sha256`) and
`built`. `package.sh` verifies it survived the `-tuned` rename; `smoke_test.sh` checks the installed copy.

## Procedure

1. **Build, test, package and smoke-test** at the commit being released, for one toolkit:

   ```bash
   CUDA_TAG=cu133 bash tuned/build.sh gb10        # tuned/build/cu133/cmake/ (not the repo root build/); allocates the label
   CUDA_TAG=cu133 bash tuned/full_test.sh gb10    # ctest, all labels; log in tuned/build/cu133/releases/
   CUDA_TAG=cu133 bash tuned/package.sh gb10      # tuned/build/cu133/dist/: tarball, .sha256, package-info.txt, a draft of the notes
   CUDA_TAG=cu133 bash tuned/smoke_test.sh gb10   # installs the tarball with install.sh and uses it
   ```

   `build.sh` needs the audited UI in `tools/ui/dist` (see `tuned/check-ui.sh`) and refuses a build directory
   configured for another toolkit or checkout. `full_test.sh` runs the whole ctest suite, including the `model`
   tests, which download small models from Hugging Face. `package.sh` only packages: it never tags or publishes;
   it checks the tarball as extracted (below). `smoke_test.sh` runs `install.sh` against the local tarball
   (`LLAMA_CPP_LOCAL_TARBALL` and `LLAMA_CPP_LOCAL_REPO`, no GitHub access) into a scratch directory, which
   itself verifies the checksum, that every library resolves, that a CUDA device is seen and that a ~1 MB model
   serves a completion (this needs network access for the model); it then checks the installed `--version`, the
   stamp and `BUILD_INFO.json`, that the libraries resolve inside the install, and the helper files.
2. **If the label was taken meanwhile** (the dry run in step 4 says the tag already exists), do not rebuild and
   retest by hand:

   ```bash
   CUDA_TAG=cu133 bash tuned/relabel.sh gb10
   CUDA_TAG=cu133 bash tuned/package.sh gb10
   CUDA_TAG=cu133 bash tuned/smoke_test.sh gb10
   ```

   `relabel.sh` checks the build is the tested one at `HEAD`, snapshots every ELF file section by section
   (sha256, with the 64-byte label buffer masked), rebuilds with the next free label, and compares: only the
   label bytes and the derived build id may differ (`tuned/elf_section_diff.py`). If so it writes
   `<build>/relabel.json` and `release.sh` accepts it in place of a test log newer than the build; the notes say
   the release was relabelled. If anything else differs it refuses, and you run `full_test.sh`.
3. **Review and commit the release notes**, `tuned/releases/RELEASE_NOTES_0.<date>.<seq>_<variant>_<cuda>.md`:
   check the text (the "Tested on" section comes from `tuned/tested-drivers.txt` and names older releases),
   delete the DRAFT line, commit and push. This must be a notes-only commit: any other change after packaging
   means building, testing and packaging again (the gate refuses it, and the binaries carry the build number
   of the commit they were built from).
4. **Gates:**

   ```bash
   CUDA_TAG=cu133 bash tuned/release.sh gb10      # or CUDA_VER=13.3
   ```

   One of `CUDA_TAG` or `CUDA_VER` is required: there is no default toolkit. With neither, the scripts fail and list
   the defined toolkits (run from a terminal they ask which to use, for that run only). For a preflight-only check
   add `--preflight-only`. When every gate passes it prints `READY` and writes `RELEASE_READY_<variant>` in the
   toolkit's `releases/` directory.
5. **Publish** with `CUDA_TAG=cu133 bash tuned/publish.sh gb10`. It refuses unless HEAD, the notes and every asset
   are unchanged since the gates passed, then creates the GitHub release targeting `tuned-builds` with the
   tarball, its `.sha256`, the notes file, the test log and the smoke log. This is the only step that changes
   anything remote.

`release.sh` never builds, tests or packages. The release is named by the label in
`package-info.txt`, not by `HEAD`, so the notes commit does not change the tag.

## Gates

All are checked and all failures are reported together, before anything is tagged or
published.

Preflight:

- working tree clean, on `tuned-builds`, `HEAD == origin/tuned-builds` (the release is
  created with `--target tuned-builds`, so the tag and the release must agree);
- `gh` authenticated;
- the binary release tag recorded in `package-info.txt` has a date label and does not already exist (if it does, step 2: relabel);
- the selected toolkit matches its definition: `nvcc` reports the declared release and the
  installed `libnccl2` is the declared version, at the toolkit-versioned `CUDA_HOME`. The
  unversioned `/usr/local/cuda` symlink is never used;
- if the build directory is already configured, its CUDA compiler is that toolkit's `nvcc`.

Test: either `tuned/build/<cuda-tag>/releases/TEST_RESULTS_<variant>.log` ends with
"Full test suite summary: ctest passed" and is newer than every `llama-*` binary and
`lib*.so*` in the build's `bin/`. `package.sh` stamps only the staged copies, so packaging
does not make the build newer than its tests. Or `<build>/relabel.json` is valid: it names this release as
its `to`, carries the hash and commit of that log, and is newer than the binaries (`tuned/relabel.sh`).

Package: `package-info.txt` is for this toolkit; the tarball matches its `.sha256`, is
newer than the test log (so it was made from the tested build), and a passing smoke log
(`tuned/build/<cuda-tag>/releases/SMOKE_RESULTS_<variant>.log`) is newer than it; only files under
`tuned/releases/` changed between the packaged commit and `HEAD`.

Notes: the notes file exists and no longer carries the DRAFT line.

## What `package.sh` checks in the tarball

After writing the tarball, `package.sh` extracts it to a temporary directory and checks:

- the `.sha256` sidecar matches;
- the extracted `llama-server-tuned --version` reports the build number and commit that
  `tuned/env.sh` derived for `HEAD` (catches packaging a stale binary);
- every ELF file resolves all its libraries with `ldd`, and its `RUNPATH`, if any, is
  exactly `$ORIGIN` (catches a missing `*-impl.so` or `libnccl`, and a leftover absolute
  build path);
- `libcudart`, `libcublas` and `libcublasLt` resolve under the selected toolkit's
  directory. These checks run with the toolkit's own lib directory first on
  `LD_LIBRARY_PATH`, because this host's `ld.so.conf` follows the `/usr/local/cuda`
  symlink and could otherwise satisfy them from another version. That pins the test
  run; it cannot decide what a deployed machine resolves, since these libraries are
  deliberately not bundled.

If any check fails there is no `package-info.txt`, and `release.sh` has nothing to
release.

## Toolkit and build settings

- `tuned/common-data/` is vendored from [zbrad/tuned-common](https://github.com/zbrad/tuned-common)
  with `tuned/sync-common.sh sync`: the shared device file (`devices/gb10.conf`:
  platform, arch, hardware label) and the toolkit definitions
  (`toolkits/cuNNN.env`: versioned `CUDA_HOME`, `nvcc` release, `libnccl2`
  version). Do not edit them here; change them in tuned-common.
- `tuned/repo.env` holds this repo's own settings, currently the CMake flags
  (`LLAMA_TUNED_CMAKE_FLAGS`) that `release.sh` configures with. It is tracked,
  so a release is reproducible, and it may not change any shared key: any
  attempt to change the hardware, toolkit or `CUDA_*` values is a loud error
  listing every conflict.
- A new toolkit is added in tuned-common as `toolkits/cuNNN.env` from values read
  off a real install, then vendored here. A toolkit with no definition cannot be
  used, even if it is installed.

## Rollback

Deleting a release is the only supported undo; consumers that already
downloaded it keep what they have.

```bash
gh release delete v0.20261016.0-gb10-cu133 --repo zbrad/llama.cpp --cleanup-tag --yes
```

Then fix the cause and release again; the freed label is allocated to the next build. A tag
that was published should not be re-pointed.

## Consumers

- `install.sh` resolves the newest matching release first and fetches its helper files from that
  release's tag (`REPO_REF` overrides). The entry point to pipe is the branch URL,
  `https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh`, which always has the
  current installer.
- zbrad/ollama's fetch script reads the tarball and expects `llama-server` and
  `llama-quantize` plus their libraries; `tuned/package.sh` lists that set.

## Notes for the maintainer

- Draft release notes are redacted by `package.sh` using `tuned/hostname-aliases.local` (gitignored;
  copy `tuned/hostname-aliases.local.example`). If the file is missing the
  redaction is skipped silently, so create it before publishing. In notes and
  docs use the generic `geo-a-node-gb10-N` form, never real hostnames.
- `tuned/build/<cuda-tag>/dist/` is gitignored and holds the tarball, checksum and `package-info.txt`; the release
  notes are the tracked file under `tuned/releases/`.
