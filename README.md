# oc2-mirror

Unofficial mirror of **opencode v2** (`opencode2`) binaries as GitHub release assets.

Upstream ([anomalyco/opencode](https://github.com/anomalyco/opencode)) publishes
the v2 CLI binaries to npm (`@opencode/cli` + per-architecture packages) and
serves them from opencode.ai — but does not attach them to GitHub releases.
This repo closes that gap: a scheduled workflow polls npm and mirrors each new
build here, with integrity verification and checksums.

Assets are named `opencode2-*`. `opencode2` is the alias the official
installer keeps for the v2 `opencode` binary, so each asset is the unmodified
official build, just filed under the name most people install it as.

## Install

Pick the asset matching your platform from the
[releases page](../../releases) (e.g. `opencode2-linux-x64`,
`opencode2-darwin-arm64`, `opencode2-windows-x64.exe`):

```sh
# example: linux x64
curl -fsSL -o opencode2 https://github.com/jaykv/oc2-mirror/releases/latest/download/opencode2-linux-x64
chmod +x opencode2
sudo mv opencode2 /usr/local/bin/
opencode2 --version
```

Verify against `SHA256SUMS.txt` attached to each release:

```sh
curl -fsSL -O https://github.com/jaykv/oc2-mirror/releases/latest/download/SHA256SUMS.txt
sha256sum -c SHA256SUMS.txt --ignore-missing
```

## How it works

- `.github/workflows/mirror.yml` runs every 6 hours (and on demand).
- `scripts/mirror.sh` resolves the npm `latest` dist-tag of `@opencode/cli`
  (currently the 2.x line), downloads every per-arch binary package, verifies
  each tarball against its registry-published sha512 integrity hash, extracts
  the `opencode` binary, and publishes a release named after the version
  (e.g. `v2.0.21`) with one asset per platform plus `SHA256SUMS.txt`.
- Release notes record provenance: the opencode.ai update-channel version,
  the upstream build commit and Actions run id, and every source tarball.
- Already-mirrored versions are skipped automatically.

To mirror a different npm channel, run the workflow manually and choose the
`npm_tag` input (`latest`, `beta`, or `dev`).

## Disclaimer

Unofficial mirror, not affiliated with the OpenCode team. Binaries are
unmodified copies of the official npm-published builds. Use at your own
discretion.
