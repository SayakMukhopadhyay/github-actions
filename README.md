# Personal GitHub Actions

Seven composite GitHub Actions for Go applications, container images, Helm charts, and GitOps promotion. All custom logic is readable Bash; invoked official actions are pinned to immutable commits.

The repository is not published yet. The documented `@v1` references become valid only after a separately authorized release.

## Input conventions

- Use descriptive kebab-case names such as `working-directory`, `go-version`, `environment`, and `target-repository`.
- Credential inputs use generic names such as `token`, `username`, and `password`; `token` may be a GitHub token, GitHub App installation token, or narrowly scoped fallback PAT as appropriate.
- Boolean values are lowercase `true` or `false`.
- V1 supports Go and Helm project metadata. Node, Python, Java, Yarn, and protobuf generation are not included.
- V1 targets GitHub-hosted Ubuntu runners. Helm metadata actions require the runner-provided `yq` v4.

## `check-version`

`SayakMukhopadhyay/github-actions/check-version@v1` always validates the root application `VERSION`. With `helm: true`, it also validates the independent `charts/VERSION`, `Chart.yaml.version`, and `Chart.yaml.appVersion`.

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  with:
    persist-credentials: false
- uses: SayakMukhopadhyay/github-actions/check-version@v1
  with:
    working-directory: .
    helm: 'true'
```

The action is read-only and requires the caller's checkout to have `contents: read`.

## `is-file-changed`

`SayakMukhopadhyay/github-actions/is-file-changed@v1` is a composite Bash action. It checks a POSIX extended regular expression against the complete push range, including multi-commit and force pushes, initial pushes, deletes, renames, and copies.

```yaml
- id: version-changed
  uses: SayakMukhopadhyay/github-actions/is-file-changed@v1
  with:
    pattern: '^VERSION$'
```

Inputs are `pattern` and optional `token`; output is `changed`. It supports `push` events and requires `contents: read`.

## `bump-version`

`SayakMukhopadhyay/github-actions/bump-version@v1` keeps independent `go` and `helm` selectors. Go-only bumps the application authority, Helm-only bumps the independent chart authority, and selecting both also synchronizes `Chart.yaml.appVersion`.

```yaml
permissions:
  contents: write

steps:
  - uses: SayakMukhopadhyay/github-actions/bump-version@v1
    with:
      token: ${{ github.token }}
      increment: patch
      go: 'true'
      helm: 'true'
```

`increment` accepts `patch`, `minor`, or `major`. The action validates consistency first, implements increments internally, stages only selected files, commits with the GitHub Actions bot identity, and pushes without force.

## `checkout-dependencies`

`SayakMukhopadhyay/github-actions/checkout-dependencies@v1` checks out a Go repository, configures the requested Go version, caches against the module's `go.sum`, and runs `go mod download`.

```yaml
- uses: SayakMukhopadhyay/github-actions/checkout-dependencies@v1
  with:
    go-version: '1.27'
    working-directory: api-server
```

## `container-build-push`

`SayakMukhopadhyay/github-actions/container-build-push@v1` builds and optionally publishes `registry/image-repository[/component]:version`. It preserves the reference action's component and additional-build-context behavior, forwards optional multiline `build-args` unchanged to Docker Buildx, and passes the existing optional `auth-token` input to BuildKit safely.

```yaml
- uses: SayakMukhopadhyay/github-actions/container-build-push@v1
  with:
    version: ${{ env.VERSION }}
    registry: ghcr.io
    image-repository: ${{ github.repository }}
    working-directory: .
    build-args: |
      VERSION=${{ env.VERSION }}
      COMMIT=${{ github.sha }}
    push: 'false'
```

In this example, the caller obtains `VERSION` from its authoritative root `VERSION` file; `COMMIT` is the current GitHub SHA. These build arguments can populate application linker metadata, while the action independently supplies dynamic OCI `created`, `version`, `revision`, and `source` labels. Build arguments are not secrets: use `auth-token` for the supported BuildKit secret and never put credentials in `build-args`.

For publication, provide `username` and `password` (the password may be `github.token`). GHCR requires `packages: write`.

## `helm-package-push`

`SayakMukhopadhyay/github-actions/helm-package-push@v1` validates the independent chart version authority, builds dependencies, lints, packages in the chart directory, and optionally pushes through Helm OCI.

```yaml
- id: chart
  uses: SayakMukhopadhyay/github-actions/helm-package-push@v1
  with:
    development: 'true'
    app-version: build-${{ github.sha }}
    registry: ghcr.io
    repository: ${{ github.repository_owner }}/charts
    working-directory: .
    push: 'false'
```

For publication, provide `username` and `password`. Outputs are `chart-name` and `chart-version`.

## `chart-update-deploy`

`SayakMukhopadhyay/github-actions/chart-update-deploy@v1` promotes one Helm dependency in a caller-selected GitOps wrapper chart.

```yaml
- uses: SayakMukhopadhyay/github-actions/chart-update-deploy@v1
  with:
    token: ${{ steps.app-token.outputs.token }}
    environment: dev
    chart-name: golfs
    chart-version: 0.7.5-${{ github.sha }}
    dependency: golfs
    target-repository: SayakMukhopadhyay/k8s-landscape-charts
    wrapper-chart-path: golfs/envs/hetzner-fsn1-dc4-prod/dev
```

The preferred `token` is a short-lived GitHub App installation token limited to the target repository with `contents: write`; a repository-limited fine-grained PAT is the fallback. Optional OCI authentication uses `registry`, `username`, and `password`.

The action permits only the selected `Chart.yaml`, `Chart.lock`, and dependency archives to change, stages exactly those files, rejects stale no-ops, and relies on a normal non-force push to reject races.

## Development and release

CI runs metadata validation, ShellCheck, shfmt, actionlint, zizmor, Bats fixtures, container builds, and Helm packaging. No local test publishes artifacts, writes to a live repository, creates releases, or contacts a cluster.

No remote, release, package, or moving `v1` tag will be created without explicit authorization.

Copyright 2026 Sayak Mukhopadhyay. All rights reserved. No license is granted for use, modification, or distribution.
