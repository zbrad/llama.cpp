# Releasing a tuned build

How a tuned GB10 build of this fork is released. This is the maintainer
procedure; to just install a published build, see the Quick Start in
[README.md](README.md). `docs/release.md` in this repo is upstream's and does
not describe this process.

`tuned/release.sh` does the work. It is a **dry run unless you pass
`--publish`**: the build, packaging and verification really run, but nothing is
tagged, pushed or published.

## What a release is

Two things are released together:

| What | Name | Used by |
|---|---|---|
| Source tag | `tuning-YYYYMMDD` (e.g. `tuning-20261008`) | `install.sh` fetches `llmsrv.sh`, `models/aliases.json` etc. from this tag (`REPO_REF`) |
| Binary release | `v<build>-<variant>-<cuda>` (e.g. `v11238-gb10-cu133`) | `install.sh` picks it by variant and CUDA version; zbrad/ollama's fetch script consumes the tarball |

`<build>` is `git rev-list --count HEAD`, the same value `llama-server
--version` reports. Do not change the binary tag shape without changing the
pattern in `install.sh` (`^v[0-9]+-<variant>-cu[0-9]+$`).

Older source tags `tuning-vN` exist and keep working. They were a hand-kept
counter and have been superseded by the date form; nothing parses the `N`.

## Procedure

1. **Bump the pin by hand, in its own commit.** In `install.sh`, set the
   default in `REPO_REF="${REPO_REF:-tuning-YYYYMMDD}"` to today's date, and
   update the example URL in the header. Commit and push to `tuned-builds`.
   The tag will point at this commit, so the tagged tree contains the pin that
   names its own tag. `release.sh` does not edit the pin.
2. **Dry run:**

   ```bash
   bash tuned/release.sh gb10                 # or CUDA_TAG=cu133 / CUDA_VER=13.3
   ```

   The toolkit is chosen from the definitions in `tuned/common-data/toolkits/`
   (see "Toolkit and build settings"). With neither `CUDA_TAG` nor `CUDA_VER`
   set it uses the highest defined toolkit and prints the available list and
   why, so the `cuNNN` part of the release name is never a surprise. For a
   gates-only check that builds nothing, add `--preflight-only`.
3. **Publish** by re-running with `--publish`. It tags the source tag on
   `HEAD`, pushes it to `origin`, then creates the GitHub release targeting
   `tuned-builds`. This is the only step that changes anything remote.

`--skip-build` reuses the existing build directory. The version check below
still catches a stale binary.

## Preflight gates

All are checked and all failures are reported together, before anything is
built:

- working tree clean, on `tuned-builds`, `HEAD == origin/tuned-builds` (the
  release is created with `--target tuned-builds`, so the tag and the release
  must agree);
- `gh` authenticated;
- `install.sh` `REPO_REF` is `tuning-YYYYMMDD`, dated today, and that tag does
  not exist locally or on `origin`;
- the binary release `v<build>-<variant>-<cuda>` does not already exist;
- the selected toolkit matches its definition: `nvcc` reports the declared
  release and the installed `libnccl2` package is the declared version, at the
  toolkit-versioned `CUDA_HOME`. The unversioned `/usr/local/cuda` symlink is
  never used, and an inherited `CUDA_HOME` that points elsewhere is rejected;
- if the build directory is already configured, its CUDA compiler is that
  toolkit's `nvcc`. The script never deletes a build directory; use another
  `LLAMA_TUNED_BUILD_DIR` or remove it yourself.

## Verification

After packaging (`tuned/package.sh` with `LLAMA_TUNED_NO_PUBLISH=1`), the script
extracts the tarball to a temporary directory and checks:

- the `.sha256` sidecar matches;
- the extracted `llama-server --version` reports the build number and commit
  that `tuned/env.sh` derived for `HEAD` (catches packaging a stale binary);
- every ELF file resolves all its libraries with `ldd` and its `RUNPATH`, if any,
  is exactly `$ORIGIN` (catches a missing `*-impl.so` or `libnccl`, and a
  leftover absolute build path);
- `libcudart`, `libcublas` and `libcublasLt` resolve under the selected
  toolkit's directory. These checks run with the toolkit's own lib directory
  first on `LD_LIBRARY_PATH`, because this host's `ld.so.conf` follows the
  `/usr/local/cuda` symlink and could otherwise satisfy them from another
  version. That pins the test run; it cannot decide what a deployed machine
  resolves, since these libraries are deliberately not bundled.

If any check fails, nothing is tagged or published.

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

- Release notes are redacted using `tuned/hostname-aliases.local` (gitignored;
  copy `tuned/hostname-aliases.local.example`). If the file is missing the
  redaction is skipped silently, so create it before publishing. In notes and
  docs use the generic `geo-a-node-gb10-N` form, never real hostnames.
- `dist/` is gitignored and holds the tarball, checksum and the generated
  `release-tag.txt`, `release-title.txt`, `release-notes.md`.
