# llmsrv.sh — GB10 Multi-Model Launcher

`tuned/llmsrv.sh` runs any GGUF model in `models/aliases.json` via bare
`llama-server`, as a systemd `--user` service, with safety checks specific
to GB10's shared unified-memory architecture. Originally named `nemo.sh`
(it only served Nemotron-3-Super at first); renamed once it grew into a
general-purpose launcher for whatever model is configured, Nemotron or not.

## Usage

```bash
llmsrv.sh [--model <name-from-aliases.json>|<path>] [start|stop|status|restart]
```

`--model` defaults to whatever the first entry in `aliases.json` is
configured as; the command defaults to `start`. Known model names come
from `models/aliases.json`'s `search_paths` + `models` table — see that
file's own header comment for the resolution order. A bare absolute path
also works, for a model not in the table.

### Env overrides

| Variable | Meaning | Default |
|---|---|---|
| `LLMSRV_HOME` | explicit install dir, for an `install.sh --dir` target other than the default (see below) | (unset -- falls back to checkout/default-location detection) |
| `LLMSRV_HOST` | bind address | `0.0.0.0` |
| `LLMSRV_CTX_SIZE` | context-size ceiling (still capped to the model's own trained context if that's smaller — see below) | `262144` |
| `LLMSRV_MEM_MARGIN_GIB` | runtime overhead margin beyond weights+KV | `8` |
| `LLMSRV_PRIMARY_HOST` | host consumers (e.g. Open WebUI) run on; anywhere else is tagged "(remote)" | `$(hostname)` -- this host is assumed primary unless told otherwise. A real multi-node deployment sets this per node, in each node's own local environment (not committed) |
| `LLMSRV_PORT` | override the alias table's per-model default port | (from `aliases.json`) |
| `LLMSRV_START_TIMEOUT_SEC` | how long to wait for `/health` before giving up | `300` |
| `LLMSRV_CRITICAL_MEM_GIB` | `MemAvailable` abort floor during startup | `2` |
| `LLMSRV_SLOT_SAVE_DIR` | per-model subdir for `/slots` save/restore/erase | `~/models/llmsrv-slots` |

## Getting llmsrv.sh + a matching binary

On a full checkout (node-1/node-2 today), `llmsrv.sh` finds everything
relative to the repo itself -- nothing else needed.

On a machine with no checkout at all, `install.sh` (repo root) fetches a
matching zbrad/llama.cpp GPU release (checksum-verified against a published
`.sha256` sidecar), `models/aliases.json`, the chat templates it
references, and `llmsrv.sh` itself, into one directory:

```bash
curl -fsSL https://raw.githubusercontent.com/zbrad/llama.cpp/tuned-builds/install.sh | bash
```

Default install location is `$XDG_DATA_HOME/llmsrv` (usually
`~/.local/share/llmsrv`), symlinked onto `~/.local/bin` -- `llmsrv.sh` then
works with no extra setup, same as a checkout. Pass `--dir <path>` for
anywhere else (including the current folder); in that case, tell
`llmsrv.sh` where to look via `LLMSRV_HOME=<path>` (the script prints the
exact command to use at the end).

`install.sh` itself is pinned by default to a `tuning-vN` tag rather than
floating on the `tuned-builds` branch tip, so it doesn't drift for reasons
unrelated to the installer (an upstream sync, an unrelated tuning commit,
etc.) -- see its own header comment for the full set of overrides
(`REPO_REF` to pin an exact tag/commit, `LLAMA_CPP_TAG` to pin an exact GPU
release instead of auto-detecting).

## Process management

Generates and drives a systemd `--user` unit (`llmsrv-<alias>.service`)
rather than a bare backgrounded process — no sudo needed for
start/stop/restart, multiple models can run as parallel units on their own
ports without colliding, and `journalctl --user -u llmsrv-<alias>.service`
gets you real logs. `--user` services stop when the login session ends
unless linger is enabled for the account (`loginctl enable-linger`) — the
script doesn't attempt this itself, since it's a one-time, possibly
privileged step outside its scope.

## Memory safety on unified memory

GB10 (Grace-Blackwell chip-to-chip memory) is one coherent ~121GiB pool —
there's no separate, smaller VRAM tier the way a discrete GPU has, so a
model server and a completely unrelated GPU-heavy process (e.g. an image/
video generation server) draw from the *same* memory, with nothing
enforcing a boundary between them by default. `llmsrv.sh` carries three
layers of protection against overcommitting that shared pool, all added
after a real incident:

**The incident (2026-09-06)**: a forced `--ctx-size 262144` on a model
trained for a 40960-token context (6.4x smaller) massively over-sized its
KV cache while another GPU-resident process was already using a large
share of the pool. The resulting allocation pressure wedged an
NVIDIA-driver-internal lock — even `nvidia-smi` hung — for 16+ minutes
before the kernel's own hung-task detector caught up, by which point the
box was unrecoverable: no OOM-killer fired, no hardware watchdog existed
yet, and it stayed hard-locked for ~19h45m until a manual power-cycle.

1. **`--ctx-size` is capped to the model's own trained context.** Read
   straight from the GGUF header (`general.architecture` +
   `<arch>.context_length`) via this repo's vendored `gguf-py`, no model
   load required. If `LLMSRV_CTX_SIZE` (or its default) would exceed the
   model's real ceiling, it's silently reduced to that instead of
   over-allocating a KV cache the model was never trained to use.
2. **`check_mem` pre-flight** computes an explicit estimate — model
   weights (file size) + KV cache (from the same GGUF metadata: block
   count, KV head count, key/value dims, at the now-capped context size) +
   a runtime margin — against current `/proc/meminfo` `MemAvailable`, and
   refuses to start if it doesn't fit. Hybrid Mamba/SSM architectures
   report no KV-cache-relevant attention heads, so their estimate falls
   back to weights-only, which has proven adequate in practice for the
   models this launches. `MemAvailable` genuinely reflects the shared
   pool's real pressure here, unlike per-cgroup memory accounting (which
   does **not** see CUDA/UVM allocations on this platform at all — a
   `cgroup` `MemoryMax`/`OOMPolicy` ceiling was tried as a defense and
   empirically falsified for exactly this reason, then dropped again;
   `MemAvailable` is the one signal that actually works here).
3. **`wait_for_healthy_or_die`** polls the freshly-started unit's
   `/health` every 2 seconds and — the moment either the process exits on
   its own or `MemAvailable` collapses below `LLMSRV_CRITICAL_MEM_GIB` —
   **stops the unit** rather than letting it keep running. This is what
   was missing in the incident: the old fire-and-forget `start` never
   watched for a startup-time collapse at all. Stopping (not just
   detecting) the unit is the point — `Restart=on-failure` only helps once
   a process has actually exited, and a process wedged holding a driver
   lock never gets there on its own; catching the collapse in seconds
   instead of minutes reclaims the memory before the lock forms.

### `--n-gpu-layers 99`

Fixed at `99` for every model rather than scaled to model size — this is
llama.cpp's standard "offload every layer" idiom (`llama-server` clamps it
to the model's real layer count internally; every model this launches has
well under 99 layers). It's fixed rather than computed because GB10's
unified memory means there's no separate, smaller VRAM ceiling to trade
against the way there would be on a discrete GPU — forcing every layer
onto the GPU costs nothing extra here. On a genuine discrete-GPU box that
assumption is false (forcing all layers onto a much smaller VRAM pool can
OOM/crash the GPU instead of degrading gracefully), so the script warns
loudly at startup if `nvidia-smi` ever reports a real VRAM size instead of
GB10's characteristic `N/A`.

## Design notes

- Model table (`models/aliases.json`) is JSON, read only by this script —
  separate from llama-server's own native `--models-preset`/router
  mechanism, which is INI-only (`docs/preset.md`; see `tuned/models.ini`
  for the router-mode equivalent of this table, kept in sync manually).
- `resolve_launch_config` (the GGUF read, ctx-size capping, and
  `--n-gpu-layers` VRAM check) only runs for `start`/`restart` — `status`
  and `stop` don't pay for a GGUF read.
- `check_mem`'s near-miss path does an opportunistic `sync` +
  best-effort `drop_caches` (via `sudo -n`, which fails fast and silently
  if passwordless sudo isn't configured) before giving up — start/stop/
  restart themselves never require sudo either way.

## References

- [README.md](README.md) — general GB10/llama.cpp build and load-time
  performance notes
- [nemotron-super-spark.md](nemotron-super-spark.md),
  [nemotron-nano-gb10.md](nemotron-nano-gb10.md) — per-model launch flags
  and quantization notes for two of the models this script serves
- [install.sh](../../install.sh) — the release-only setup script described
  above
