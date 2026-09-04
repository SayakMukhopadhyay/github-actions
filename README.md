# Personal GitHub Actions

Eight GitHub Actions for Go applications, container images, Helm charts, GitOps promotion, and GitHub Releases. Workflow orchestration stays in composite actions; parsing, validation, and file mutation that benefits from structured code is authored in TypeScript and committed as bundled ESM. Invoked external actions are pinned to immutable commits.

The existing `@v1` release contains the original seven actions. The new `create-release` action is available from the repository only after a separately authorized release updates the public version reference.

## Input conventions

- Use descriptive kebab-case names such as `working-directory`, `go-version`, `environment`, and `target-repository`.
- Credential inputs use generic names such as `token`, `username`, and `password`; `token` may be a GitHub token, GitHub App installation token, or narrowly scoped fallback PAT as appropriate.
- Boolean values are lowercase `true` or `false`.
- V1 supports Go and Helm project metadata. Node, Python, Java, Yarn, and protobuf generation are not included.
- V1 targets GitHub-hosted Ubuntu runners. `chart-update-deploy` requires `yq` v4; the TypeScript-backed version and packaging actions parse YAML from their bundles.

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

`SayakMukhopadhyay/github-actions/is-file-changed@v1` is a composite action. Its shell collector obtains the complete push range, including multi-commit and force pushes, initial pushes, deletes, renames, and copies. Its TypeScript implementation compiles `pattern` with JavaScript's `RegExp` constructor and tests both sides of rename and copy records.

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

## `create-release`

`SayakMukhopadhyay/github-actions/create-release@v1` combines explicit shell boundaries for local Git context and GitHub publication with a bundled TypeScript release-note generator. The action targets the current `github.repository` and has exactly four required inputs: `token`, `tag-name`, `release-name`, and `openai-api-key`.

```yaml
permissions:
  contents: write

steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    with:
      fetch-depth: 0
      persist-credentials: false
  - id: release
    uses: SayakMukhopadhyay/github-actions/create-release@v1
    with:
      token: ${{ github.token }}
      tag-name: ${{ needs.version.outputs.tag-name }}
      release-name: Release ${{ needs.version.outputs.tag-name }}
      openai-api-key: ${{ secrets.OPENAI_API_KEY }}
```

The supplied tag must already exist in the current GitHub repository. The pinned checkout receives the GitHub token long enough to obtain complete local history without persisting credentials. The secret-free collector then derives release facts from that checkout. The action never creates, moves, or overwrites a tag, and its publisher re-verifies the remote tag immediately before creating a published, non-draft, non-prerelease Release. A retry returns an existing matching Release unchanged, including races where another run creates it first.

The semantic-version suffix determines the release family. For example, `v0.0.1`, `chart-v0.0.1`, and `charts/0.0.1` compare only with lower versions sharing their exact respective prefixes. The first release in a family links to its tagged source instead of emitting an invalid comparison. Git supplies the exact first-parent commit list, commit URLs, and comparison/source URL; merge commits appear as mainline entries while their individual branch commits do not.

The action sends bounded commit subjects, changed-file statistics, and a size-limited diff to the OpenAI Responses API as explicitly untrusted repository data. It pins `gpt-5.6-luna`, disables storage, supplies no tools, requests a strict JSON schema, and validates the returned plain-text description and highlights before composing Markdown. OpenAI never supplies tags, versions, commit entries, artifact references, or links. An unavailable, refused, incomplete, malformed, or unsafe AI response fails before GitHub Release creation.

Outputs are `release-id`, `html-url`, and `upload-url`, corresponding to the useful ID, HTML URL, and upload URL values exposed by the legacy action.

The checkout sees only the GitHub token. The collector receives no secrets. The generator receives only the OpenAI key and secret-free context. The publisher receives only the GitHub token and the locally validated release body. No process receives both credentials.

The caller retains events, jobs, `needs`, conditions, permissions, environments, concurrency, publication ordering, approval gates, and the decision to run application and chart releases independently. This action owns only tag verification, family/range derivation, bounded note generation, deterministic Markdown composition, idempotency, and Release creation.

## Consumer workflow schema

Editors can combine SchemaStore's GitHub workflow completion with this repository's generated action-input contracts by placing this comment at the top of a workflow:

```yaml
# $schema: https://raw.githubusercontent.com/SayakMukhopadhyay/github-actions/v1/schemas/github-workflow.schema.json
```

The public wrapper references SchemaStore's live workflow schema and the committed `schemas/action-inputs.schema.json` overlay. The overlay is generated from the eight public `action.yaml` files, which remain the sole contract authority. It validates inputs for this repository's `@v1` action paths; it does not attempt to interpret output names embedded in GitHub expressions.

## Development

The repository is one npm package and does not use workspaces. Each executable action keeps its TypeScript entry point, `action.yaml`, and generated `dist/index.mjs` together:

- `check-version/` is directly callable as a JavaScript action.
- `actions/is-file-changed/`, `actions/bump-version/`, `actions/helm-package-push/`, and `actions/create-release/` are implementation actions invoked by their public composite wrappers.
- `tooling/` contains only repository-maintenance programs such as schema generation and file-only contract comparison.

There is no general shared-code directory. Common modules should be extracted only after two implemented actions demonstrate identical behavior.

Install the exact locked dependencies with Node `24.20.0`:

```shell
npm ci
```

The main development checks are:

```shell
npm run typecheck
npm run lint
npm run format:check
npm run test:node
npm run test:shell
npm run schema:generate
npm run bundle
```

The five `bundle:<action>` scripts call Rolldown directly and can be run individually. No custom TypeScript bundle driver is used.

TypeScript in this repository—production actions, tooling, and tests—must never spawn an external process. It may parse files and use JavaScript facilities such as the `RegExp` constructor. Git, Helm, `yq`, and GitHub CLI transactions belong in checked shell files or composite steps. Shell integration tests invoke those command boundaries directly rather than through Node.

Node tests and shell fixtures are hermetic and credential-free. They use temporary repositories, local charts, stubbed executables, injected OpenAI clients, and captured GitHub output files. They never publish a container or chart, mutate a live Git remote, create a GitHub Release, call OpenAI, or contact a cluster.

## Generated artifacts

TypeScript sources, public and implementation metadata, ESM bundles, external source maps, generated schemas, package metadata, and the npm lockfile are committed together. After changing source or metadata, regenerate the affected artifacts and inspect the exact diff:

```shell
npm run schema:generate
npm run bundle
git diff --check
```

CI repeats both generators and rejects any byte-level drift. Fixed output names and LF normalization keep the committed artifacts reproducible across Windows development and Ubuntu CI. Do not submit source-only changes expecting a later release build to update `dist`.

The released `v1` metadata is extracted by `tooling/extract-v1-contracts.sh`; the TypeScript compatibility checker reads only those extracted files and never invokes Git or another command. Removed or renamed inputs/outputs, newly caller-required inputs, and changed existing defaults fail CI. Additive optional inputs and outputs remain compatible.

Licensed dependency metadata lives under `.licenses/npm` and is governed by `.licensed.yml`. When npm dependencies change, run `licensed cache` with Licensed `5.1.0`, review the generated records, and commit them with the lockfile. CI runs `licensed status`; it never updates or commits the cache.

## CI and v1 promotion

Ubuntu CI runs TypeScript, ESLint, Prettier, pure Node tests, shell integration tests, Ajv schema fixtures, released-contract compatibility, deterministic bundle/schema drift checks, bundle syntax smoke checks, ShellCheck, checksum-and-attestation-verified actionlint, offline Zizmor, Licensed, and credential-free container/Helm action fixtures. External actions use reviewed full commit SHAs. Dependabot opens weekly npm and GitHub Actions pull requests; updates are never automerged.

Source changes do not move `v1`. To promote or intentionally roll back, manually run the **Promote v1** workflow with a full 40-character commit SHA from `main`. The workflow verifies reachability, checks through GitHub's read-only Checks API that the exact target already passed the required main CI action-level fixtures, checks out that exact tree, reruns its source, type, lint, test, schema, contract, bundle, security, and license checks, requires the tree to remain clean, and then moves only the lightweight `v1` tag with force-with-lease protection. The composite fixtures are not repeated during promotion because their nested checkout steps resolve the workflow-dispatch event SHA rather than a dynamically selected rollback SHA. Only the final tag-push job receives `contents: write`; no semver tag or GitHub Release is created for this action repository.

Local development and ordinary CI perform no remote publication, create no live GitHub Release, and never move the `v1` tag.

Copyright 2026 Sayak Mukhopadhyay. All rights reserved. No license is granted for use, modification, or distribution.
