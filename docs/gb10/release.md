# Releasing a tuned build

How a tuned GB10 build of this fork is released. This is the maintainer
procedure; to just install a published build, see the Quick Start in
[README.md](README.md). `docs/release.md` in this repo is upstream's and does
not describe this process.

The flow is `tuned/build.sh`, `tuned/full_test.sh`, `tuned/package.sh`, then
`tuned/release.sh`, the same split as raft, cuvs and faiss. `release.sh` is a **dry
run unless you pass `--publish`**: every gate really runs, but nothing is tagged,
pushed or published.

## What a release is

Two things are released together:

| What | Name | Used by |
|---|---|---|
| Source tag | `tuning-YYYYMMDD` (e.g. `tuning-20261008`) | `install.sh` fetches `llmsrv.sh`, `models/aliases.json` etc. from this tag (`REPO_REF`) |
| Binary release | `v0.<YYYYMMDD>.<seq>-<variant>-<cuda>` (e.g. `v0.20261015.0-gb10-cu133`) | `install.sh` picks it by variant and CUDA version; zbrad/ollama's fetch script consumes the tarball |

The date is the UTC date of `HEAD`'s commit and `<seq>` is the lowest unused sequence for that
date among the repo's release tags (`0` for the first build of the day, written in full), both
from `gpu_tuned_allocate_date_label` in tuned-common (see its `docs/VERSIONING.md`).
`tuned/package.sh` allocates the label once and records it in `package-info.txt`; everything
after reads it from there. `GPU_TUNED_LABEL_SEQ=<n>` chooses the sequence without reading
`origin`'s tags. The commit count (`llama-server --version`'s "build N") is no longer part of
the name: it was unreliable as an identity. It is only checked, at packaging, against the
binary's own report.

Older release tags `v<build>-<variant>-<cuda>` (e.g. `v10931-gb10-cu133`) stay as they are;
`install.sh` accepts both shapes and prefers any date-label tag over a counter tag.

Older source tags `tuning-vN` exist and keep working. They were a hand-kept
counter and have been superseded by the date form; nothing parses the `N`.

## Procedure

1. **Bump the pin by hand, in its own commit.** In `install.sh`, set the
   default in `REPO_REF="${REPO_REF:-tuning-YYYYMMDD}"` to today's date, and
   update the example URL in the header. Commit and push to `tuned-builds`.
   The tag will point at this commit, so the tagged tree contains the pin that
   names its own tag. `release.sh` does not edit the pin.
2. **Build, test and package** at the commit being released, for one toolkit:

   ```bash
   CUDA_TAG=cu133 bash tuned/build.sh gb10        # build-tuned/cu133/gb10/ (not the shared build/)
   CUDA_TAG=cu133 bash tuned/full_test.sh gb10    # ctest, all labels; log beside the build tree
   CUDA_TAG=cu133 bash tuned/package.sh gb10      # dist/gb10/: tarball, .sha256, package-info.txt
   ```

   `build.sh` needs the audited UI in `tools/ui/dist` (see `tuned/check-ui.sh`) and
   refuses a build directory configured for another toolkit or checkout. `full_test.sh`
   runs the whole ctest suite, including the `model` tests, which download small models
   from Hugging Face. `package.sh` only packages: it never tags or publishes. It then
   checks the tarball as extracted (below) and, if there are no release notes for this
   build yet, writes a draft.
3. **Review and commit the release notes**, `tuned/releases/RELEASE_NOTES_0.<date>.<seq>_<variant>_<cuda>.md`:
   check the text (the "Tested on" section comes from `tuned/tested-drivers.txt` and names
   older releases), delete the DRAFT line, commit and push. This must be a notes-only
   commit: any other change after packaging means building, testing and packaging again (the
   gate refuses it, and the binaries carry the build number of the commit they were built from).
4. **Dry run:**

   ```bash
   CUDA_TAG=cu133 bash tuned/release.sh gb10      # or CUDA_VER=13.3
   ```

   With neither `CUDA_TAG` nor `CUDA_VER` the toolkit named in
   `tuned/common-data/toolkits/DEFAULT` is used, and the available list is printed. For a
   preflight-only check add `--preflight-only`.
5. **Publish** by re-running with `--publish`. It tags the source tag on `HEAD`, pushes it
   to `origin`, then creates the GitHub release targeting `tuned-builds` with the tarball,
   its `.sha256`, the notes file and the test log. This is the only step that changes
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
- `install.sh` `REPO_REF` is `tuning-YYYYMMDD`, dated today, and that tag does not exist
  locally or on `origin` (step 1 bumps it; `install.sh` still pins the old `tuning-vN`
  form until then);
- the binary release tag recorded in `package-info.txt` does not already exist;
- the selected toolkit matches its definition: `nvcc` reports the declared release and the
  installed `libnccl2` is the declared version, at the toolkit-versioned `CUDA_HOME`. The
  unversioned `/usr/local/cuda` symlink is never used;
- if the build directory is already configured, its CUDA compiler is that toolkit's `nvcc`.

Test: `build-tuned/<cuda-tag>/<variant>/TEST_RESULTS_<variant>.log` ends with
"Full test suite summary: ctest passed" and is newer than every `llama-*` binary and
`lib*.so*` in the build's `bin/`. `package.sh` stamps only the staged copies, so packaging
does not make the build newer than its tests.

Package: `package-info.txt` is for this toolkit; the tarball matches its `.sha256` and is
newer than the test log (so it was made from the tested build); only files under
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
gh release delete v11238-gb10-cu133 --repo zbrad/llama.cpp --cleanup-tag --yes
git push origin :refs/tags/tuning-20261008     # the source tag
git tag -d tuning-20261008
```

Then fix the cause and release again with a new `REPO_REF` date. A tag
that was published should not be re-pointed.

## Consumers

- `install.sh` fetches its helper files from `REPO_REF` and the newest matching
  binary release. A published `install.sh` that pins a tag that does not exist
  breaks every new install, which is why the pin commit comes first and the tag
  is pushed before the release is created.
- zbrad/ollama's fetch script reads the tarball and expects `llama-server` and
  `llama-quantize` plus their libraries; `tuned/package.sh` lists that set.

## Notes for the maintainer

- Draft release notes are redacted by `package.sh` using `tuned/hostname-aliases.local` (gitignored;
  copy `tuned/hostname-aliases.local.example`). If the file is missing the
  redaction is skipped silently, so create it before publishing. In notes and
  docs use the generic `geo-a-node-gb10-N` form, never real hostnames.
- `dist/` is gitignored and holds the tarball, checksum and `package-info.txt`; the release
  notes are the tracked file under `tuned/releases/`.
