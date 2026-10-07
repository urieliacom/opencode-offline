# Offline Test Environment

Containerized test environment for validating the OpenCode offline bundle in a RHEL9/UBI9 container with no outbound network access.

## Prerequisites

- Docker (with Compose v2)
- The offline bundle built at `dist/opencode-offline-linux-x64/`

## Quick Start

```bash
# 1. Build the offline bundle (from repo root)
bun install
bun run script/download-offline-deps.ts
bun run script/package-offline-bundle.ts

# 2. Verify the web app was included
ls dist/opencode-offline-linux-x64/deps/app/index.html

# 3. Run the tests
docker compose -f test/offline/docker-compose.yml up --build
```

Exit code 0 means all tests passed.

## Network Isolation Modes

### Strict (default)

The `docker-compose.yml` uses an `internal: true` network, which blocks all outbound traffic. This is the default and mirrors an air-gapped environment.

### With LLM Endpoint

To test with a local LLM (e.g., Ollama), you need to allow the container to reach the host. Edit `docker-compose.yml`:

1. Remove `internal: true` from the network config (or add a second non-internal network)
2. Set the `LLM_ENDPOINT` environment variable:

```bash
LLM_ENDPOINT=http://host.docker.internal:11434 \
  docker compose -f test/offline/docker-compose.yml up --build
```

Note: Network isolation tests will fail in permissive mode (expected).

## Interactive Exploration

Build the image and run interactively:

```bash
docker build -f test/offline/Dockerfile -t opencode-offline-test .
docker run -it --network none --entrypoint /bin/bash opencode-offline-test
```

Inside the container:

```bash
# Run the test suite
/opt/opencode/test-offline.sh

# Start the web UI
/opt/opencode/opencode-offline web

# Check versions
/opt/opencode/opencode-offline --version
/opt/opencode/deps/ripgrep/rg --version
```

## Data-Analysis Image

`Dockerfile.analysis` builds a variant of the offline image for agents that analyse large CSV data
sets described by Markdown documents. Unlike the UBI9 integration-test image, it uses the official
Python 3.13.16 slim Debian Trixie runtime. It contains the same offline bundle plus a CLI toolbox, and
every tool is on `PATH` (including the bundled `rg` and `opencode`, which are symlinked into
`/opt/opencode/tools/bin`), so the agent can run them directly from its shell.

```bash
# 1. Build the offline bundle first (see Quick Start above)
# 2. Build the analysis image
docker build --pull --no-cache -f test/offline/Dockerfile.analysis -t opencode-offline-analysis .

# 3. Verify the toolbox and security regression checks
docker run --rm --network none --entrypoint /opt/opencode/test-analysis-tools.sh opencode-offline-analysis

# or via compose, mounting your data set read-only at /home/opencode/data
ANALYSIS_DATA=/path/to/csv-and-md docker compose -f test/offline/docker-compose.analysis.yml up --build

# Interactive session with the agent
docker run -it --rm -v /path/to/csv-and-md:/home/opencode/data:ro opencode-offline-analysis
```

### Publishing the analysis image to GHCR

Building the image locally needs outbound access to Docker Hub, Debian repos, the Go module proxy
and checksum database (Miller), and PyPI, so it
cannot be built from an air-gapped machine. The `Offline Analysis Image` workflow
(`.github/workflows/offline-analysis-image.yml`) does the whole chain on a GitHub runner: build the
offline bundle, run the offline integration tests, build `Dockerfile.analysis`, run the analysis
toolbox checks on the `internal: true` network, then push to
`ghcr.io/<owner>/<repo>-analysis:<tag>`.

Trigger it from the Actions tab (**Offline Analysis Image** → **Run workflow**) or from the CLI:

```bash
gh workflow run offline-analysis-image.yml -f tag=v6
# dry run: build and test only, no push
gh workflow run offline-analysis-image.yml -f tag=v6 -f push=false
```

Pull the published image with:

```bash
docker pull ghcr.io/<owner>/opencode-offline-analysis:v6
```

Included tooling:

| Category | Tools |
|---|---|
| Search / text | `rg` (from the bundle), `jq`, `grep`, `gawk`, `sed`, `findutils`, `coreutils`, `diffutils`, `file`, `less`, `tree` |
| CSV / data | `mlr` (Miller), `python3` (venv, see below), `pip` |
| Archives | `tar`, `gzip`, `xz`, `zip`, `unzip` |
| Debugging | `curl`, `procps` (`ps`), `lsof`, `iproute2` (`ip`), `netcat-openbsd` (`nc`), `git` |

The Python analysis environment is a dedicated venv at `/opt/analysis-venv`, placed first on `PATH`,
so `python3`/`pip` resolve to it. The only underlying interpreter is Python 3.13.16 at
`/usr/local/bin/python3`; no distribution Python or DNF is installed. Packages are pinned in
`analysis-requirements.txt`: `pandas`, `numpy`, `duckdb`,
`pyarrow`, `scipy`, `tabulate`.

Notes:

- Building requires network access (Docker Hub, Debian repos, Go proxy/checksum database, PyPI). The resulting image runs
  fully air-gapped; `docker-compose.analysis.yml` uses the same `internal: true` network.
- Miller's version is controlled by the `MILLER_VERSION` build arg. It is built from checksum-verified
  Go modules with Go 1.27.1, not downloaded as a binary containing an older Go runtime.
  Build metadata is retained at `/usr/local/share/miller-build.txt`; the Go toolchain and module
  cache remain in the builder stage, not the shipped image.
- Runtime OS packages are upgraded during the build, with no recommended packages installed.
  `vim`, `libxml2`/its Python bindings, `libevent`, and `setuptools` are not needed and are absent.
  OpenBSD netcat replaces Ncat; scripts using Ncat-specific options must be adapted.
- To install extra Python packages from a local mirror, use `pip install --index-url <mirror>` inside
  the container or extend `analysis-requirements.txt` before building.

### Vulnerability verification

Rebuild with `--pull --no-cache` and scan the **final image digest** with JFrog Xray before deploying
or publishing it. The toolbox suite checks both Python environments, pip's vendored urllib3,
Miller's Go build metadata, dependency consistency, and absence of unnecessary vulnerable packages.
These regression checks are not a substitute for an Xray scan and do not guarantee a clean report.

The full offline bundle is still copied into the image, including downloaded native executables
and npm dependencies. If Xray reports another embedded Go runtime (for example an npm-provided
executable), use the reported artifact path to identify and update or rebuild its owning dependency.
Changing the Miller builder does not patch other binaries. Refresh the pinned Python and Go base
tags when new security releases become available, and assess Debian packages using Debian's
security advisories/backports rather than comparing their versions with RHEL RPM fix versions.

## Test Coverage

| Section | Tests | What it validates |
|---------|-------|-------------------|
| Environment | Env vars, directory structure | Offline config is properly set, all expected dirs/files exist |
| Binaries | opencode, ripgrep | Core binaries are executable and functional |
| Network Isolation | curl to google, app.opencode.ai, models.dev | No outbound network access |
| Web UI | Server start, root 200, HTML content, SPA fallback | Bundled web app served locally |
| LSP Servers | typescript-language-server, pyright, clangd, rust-analyzer | LSP binaries present and executable |
| CLI Commands | --help | Basic CLI functionality |

## Troubleshooting

### Build fails: "Dependencies not found"

Run `bun run script/download-offline-deps.ts` first to download dependencies.

### Web UI tests fail: "Server failed to start"

The server has 15 seconds to start. If the container is very slow, increase the timeout in `test-offline.sh` (the `seq 1 30` loop with 0.5s sleep).

### Network isolation tests pass but shouldn't

Ensure `docker-compose.yml` has `internal: true` on the network. Without it, the container can reach the internet.

### clangd/rust-analyzer version check fails

These are native Linux x64 binaries. If built on a different architecture, they won't run. Ensure `download-offline-deps.ts` was run on an x64 system or cross-downloads the correct architecture.
