# kubectl-b64edit

Inline-edit base64 encoded fields of Kubernetes resources (Secrets, ConfigMaps,
and generically any other resource) without manually copy-pasting through
`base64 -d`/`base64`. Ships as a standalone `kubectl` plugin and a matching
[k9s](https://k9scli.io) plugin (`Shift-E` to edit, `Shift-V` to view).

`kubectl get secret demo -o json | ... base64 -d ... | $EDITOR | ... base64 ...`
becomes: press `Shift-E` in k9s, edit plaintext, save.

## How it works

1. Fetches the resource (`kubectl get -o json`).
2. Decodes `Secret.data` / `ConfigMap.binaryData` values to plaintext, plus (unless
   `--no-detect`) any other string field elsewhere in the object that looks like
   base64 (strict charset/length/padding check, a clean decode round-trip, and
   printable UTF-8 content). Anything binary/gzip/non-canonical is left encoded
   and listed in the buffer header instead of guessed at.
3. Opens the result as YAML in `$K9S_EDITOR`/`$KUBE_EDITOR`/`$EDITOR`/`vi`.
4. On save, only the fields you actually changed are re-encoded; every untouched
   decoded value is restored **byte-for-byte** from the original base64 string
   (no re-encoding round-trip noise, no reordering).
5. Applies the result with `kubectl replace`, using the `resourceVersion`
   fetched in step 1 for optimistic concurrency - concurrent changes are
   rejected, never silently overwritten.

Identity/server-managed fields (`apiVersion`, `kind`, `metadata.name/namespace/
uid/resourceVersion/managedFields`, the `kubectl.kubernetes.io/last-applied-
configuration` annotation) are pinned back to their original values regardless
of what ends up in the edited buffer, so the editor can never be tricked (by a
typo, a malicious annotation, or a broken editor) into bypassing the
concurrency check or renaming/relocating the object.

## Requirements

- `kubectl`, [`jq`](https://jqlang.org) (>=1.6), [`yq`](https://github.com/mikefarah/yq)
  (the Go/mikefarah implementation - the script refuses to run against the
  unrelated Python `yq`), `sha256sum`, bash >= 4.
- RBAC: `get` and `update` (via `replace`) on the target resource.

## Install

### Via krew

Once a release has been tagged and built by CI (see below), install straight
from this repository - no clone needed:

```sh
kubectl krew install --manifest-url=https://raw.githubusercontent.com/stelucz/kubectl-b64edit/main/.krew.yaml
```

This isn't (yet) submitted to the official
[krew-index](https://github.com/kubernetes-sigs/krew-index), so it won't show
up under a plain `kubectl krew install b64edit` - the `--manifest-url` form
above is required until that submission happens. `kubectl krew uninstall
b64edit` removes it. This only installs the `kubectl-b64edit`/`kubectl
b64edit` binary - the k9s plugin file still needs `task install` (below) or a
manual copy of `plugins/b64edit.yaml`.

`.github/workflows/release.yml` builds this on every `vX.Y.Z` tag push: it
runs `task lint test`, builds the tarball with `task package`, publishes a
GitHub release with the tarball attached, and commits the resulting
`version`/`uri`/`sha256` into `.krew.yaml` on the default branch - so the
command above always installs the latest tagged release. The same
version-bump logic is available locally as `task krew-manifest-bump
VERSION=vX.Y.Z` for manual releases.

#### Local testing (before a release exists)

From a checkout, build and install whatever is currently on disk - including
uncommitted changes - bypassing whatever release `.krew.yaml` currently points
to:

```sh
task krew-install    # runs task package, then kubectl krew install --manifest=... --archive=...
task krew-uninstall  # kubectl krew uninstall b64edit
```

To also submit to the official krew-index, follow krew's [submission
guide](https://krew.sigs.k8s.io/docs/developer-guide/release/new-plugin/); the
[krew-release-bot](https://github.com/rajatjindal/krew-release-bot) GitHub
Action can automate opening that PR on every tag once the first submission is
merged.

### Via task (symlink)

```sh
task install
```

This symlinks `bin/kubectl-b64edit` into `~/.local/bin` (make sure it's on
`PATH`; it also becomes available as `kubectl b64edit ...`) and copies
`plugins/b64edit.yaml` into `${XDG_DATA_HOME:-~/.local/share}/k9s/plugins/`.
`task uninstall` reverses both steps.

### Shell completion (optional)

`kubectl` (>=1.26) supports plugin completion by looking for an executable
named `kubectl_complete-<plugin>` on `PATH` - `bin/kubectl_complete-b64edit`
completes both `TYPE` (resource kinds) and `NAME` (via `kubectl get`, scoped
to `--namespace`/`--context` if already typed) once `kubectl completion
<shell>` is sourced (see `kubectl completion --help`).

`task install` symlinks it automatically. If you installed via krew instead,
krew only exposes the main `kubectl-b64edit` binary, so link the completion
script in manually (this works regardless of install method, since it
resolves through whichever symlink is currently on `PATH`):

```sh
ln -sf "$(dirname "$(readlink -f "$(command -v kubectl-b64edit)")")/kubectl_complete-b64edit" \
  "$(dirname "$(command -v kubectl-b64edit)")/kubectl_complete-b64edit"
```

## Usage

```sh
kubectl-b64edit [options] TYPE NAME
# e.g.
kubectl-b64edit secret my-secret -n my-namespace
kubectl b64edit configmap my-configmap -n my-namespace --view
```

| Option              | Description                                                        |
|----------------------|--------------------------------------------------------------------|
| `--context CTX`      | kubectl context                                                    |
| `--namespace NS`      | namespace (required for namespaced resources)                      |
| `--kubeconfig PATH`  | kubeconfig file                                                     |
| `--view`             | read-only: print the decoded buffer, no editor, no write            |
| `--no-detect`        | only decode `Secret.data`/`ConfigMap.binaryData`, skip heuristics    |
| `--min-len N`        | minimum length to consider a string for heuristic decoding (default 16) |
| `--yes`              | skip the confirmation prompt                                        |

In k9s, select a Secret or ConfigMap and press `Shift-E` to edit or `Shift-V`
to view. The plugin works on `all` scopes; heuristic detection kicks in for
any other resource type too.

## Security notes

- All base64 decode/encode happens inside `jq`; secret values are never passed
  as command-line arguments (not visible via `ps`) and never printed to
  stdout/stderr - the confirmation summary before applying only lists **key
  names** (added/removed/modified), never values.
- The editor buffer is written to a `0700` directory under `/dev/shm` (falls
  back to `$TMPDIR`/`/tmp` if unavailable), created under `umask 077`, and
  shredded (or deleted if `shred` is unavailable) on exit - including on
  `Ctrl-C`/`SIGTERM`.
- Writes use `kubectl replace`, not `apply`, so no plaintext-bearing
  `last-applied-configuration` annotation is regenerated; the original one (if
  any) is preserved verbatim instead.
- `resourceVersion` is always taken from the original fetch, never from the
  edited buffer, so the optimistic-concurrency check can't be bypassed by
  editing or clearing that field.
- Your editor's own swap/backup/undo files (e.g. vim's `.swp`) can leak
  plaintext outside this tool's temp directory. Recommended:
  `export K9S_EDITOR="vim -n -i NONE"` (or your editor's equivalent) to disable
  them for this workflow.
- Immutable Secrets/ConfigMaps (`immutable: true`) are rejected up front.
- If the resource is labeled/owned by Helm, Argo CD, Flux, or has an
  `ownerReference`, a warning is printed before the confirmation prompt since
  the change is likely to be reverted by the owning controller.

## Testing

```sh
task lint   # shellcheck
task test   # stub kubectl/$EDITOR based test suite, no cluster needed
```

`test/` contains fixtures (plain Secret, immutable Secret, Helm-managed
Secret, ConfigMap with `binaryData`) and stub `kubectl`/editor scripts so the
whole decode -> edit -> re-encode -> apply flow is exercised without a real
cluster.

## Known limitations

- Helm release storage Secrets (double-base64 + gzip) are detected as
  non-text and kept encoded rather than decoded - editing Helm's own release
  blobs is out of scope.
- Windows is not supported (bash + `/dev/shm` assumed).
- Heuristic detection only round-trips fields it originally decoded; a
  plaintext string manually added to an arbitrary (non-`data`/`binaryData`)
  path elsewhere in the object is stored as-is, not opportunistically
  base64-encoded.
