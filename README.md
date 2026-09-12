# Personal GitHub Actions

Reusable GitHub Actions for Go and npm dependencies, Azure registry authentication, static-site delivery, container images, Helm charts, immutable release tags, GitHub Releases, and GitOps promotion and deployment verification. Actions own reusable mechanics; consuming workflows retain jobs, conditions, permissions, environments, concurrency, ordering, and approval gates. Parsing, validation, API calls, and file mutation that benefit from structured code are authored in TypeScript and committed as bundled ESM. Invoked external actions are pinned to immutable commits.

This README describes `main`. Changes on `main` are unavailable through `@v1` until the moving major tag is explicitly promoted.

## Input conventions

- Use descriptive kebab-case names such as `working-directory`, `go-version`, `environment`, and `target-repository`.
- Credential inputs use generic names such as `token`, `username`, and `password`; the Pages delivery actions use `github-token` to distinguish their GitHub API credential. A token may be a GitHub token, GitHub App installation token, or narrowly scoped fallback PAT as appropriate.
- Boolean values are lowercase `true` or `false`.
- Dependency checkout supports Go modules and lockfile-based npm projects. Python, Java, Yarn, and protobuf generation are not included.
- V1 targets GitHub-hosted Ubuntu runners. `chart-update-deploy` and `static-site-update-deploy` require `yq` v4; the TypeScript-backed version and packaging actions parse YAML from their bundles.

Registry credentials follow one shared fail-early policy:

| Action or mode                       | Credential requirement                                                         |
| ------------------------------------ | ------------------------------------------------------------------------------ |
| Container build with `push: 'true'`  | Both `username` and `password` are required.                                   |
| Container build with `push: 'false'` | Neither credential or a complete pair is accepted; a partial pair is rejected. |
| Helm package with `push: 'true'`     | Both `username` and `password` are required.                                   |
| Helm package with `push: 'false'`    | Neither credential or a complete pair is accepted; a partial pair is rejected. |
| Container inspection                 | Neither credential or a complete pair is accepted; a partial pair is rejected. |
| Container promotion                  | Both `username` and `password` are required.                                   |
| Chart update with `registry`         | Both `username` and `password` are required.                                   |
| Chart update without `registry`      | Credentials are forbidden because the action cannot use them.                  |

Validation runs before registry login and before publication or GitOps mutation. Container build uses a separate exact-reference probe step because Buildx is conditionally invoked; Helm package probes inside its transaction. Both paths use the same shared fail-closed OCI policy: only standard not-found responses mean absent, while authentication, transport, and malformed-reference failures stop the action.

## `check-version`

`SayakMukhopadhyay/github-actions/check-version@v1` always validates the canonical root application `VERSION`. With `helm: true`, it also validates the canonical `charts/VERSION`, requires `Chart.yaml.version` to match it, and requires `Chart.yaml.appVersion` to exist as a scalar without requiring it to match the application version.

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

`SayakMukhopadhyay/github-actions/is-file-changed@v1` is a composite action. Its PowerShell collector obtains the complete push range, including multi-commit and force pushes, initial pushes, deletes, renames, and copies. Its TypeScript implementation compiles `pattern` with JavaScript's `RegExp` constructor and tests both sides of rename and copy records.

```yaml
- id: version-changed
  uses: SayakMukhopadhyay/github-actions/is-file-changed@v1
  with:
    pattern: '^VERSION$'
```

Inputs are `pattern` and optional `token`; output is `changed`. It supports `push` events and requires `contents: read`.

## `bump-version`

`SayakMukhopadhyay/github-actions/bump-version@v1` keeps independent `go` and `helm` selectors. Go-only bumps the root application authority without changing chart metadata. Helm-only bumps `charts/VERSION` and `Chart.yaml.version` while synchronizing `Chart.yaml.appVersion` to the current root `VERSION`. Selecting both bumps both authorities and sets `appVersion` to the new root version.

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

`SayakMukhopadhyay/github-actions/checkout-dependencies@v1` checks out a repository once and installs explicitly selected Go and/or npm dependencies. `working-directory` defaults to `.` and is the fallback for both ecosystems. `go-working-directory` and `node-working-directory` override it independently when non-empty.

```yaml
- uses: SayakMukhopadhyay/github-actions/checkout-dependencies@v1
  with:
    go-version: '1.27'
    go-working-directory: api-server
    node-version-file: .nvmrc
    node-working-directory: documentation
```

Go setup caches against the resolved module's `go.sum` and runs `go mod download`. Node setup accepts exactly one of `node-version` or `node-version-file`, enables npm's download cache against the resolved project's `package-lock.json`, and runs deterministic `npm ci`. Supplying both Node selectors fails, as does selecting neither ecosystem. Checkout credentials are never persisted.

## `validate-static-site`

`SayakMukhopadhyay/github-actions/validate-static-site@v1` validates one built deployment directory without running a framework, build, lint, package-manager, or link-crawling command.

```yaml
- uses: SayakMukhopadhyay/github-actions/validate-static-site@v1
  with:
    path: dist
```

The required `path` must exist, be a non-empty directory, contain a regular root `index.html`, and recursively contain only directories and regular files with no symbolic links. This final-directory contract works equally for Astro output, Fumadocs/Next static output, and hand-authored HTML.

## `dispatch-pages-deployment`

`SayakMukhopadhyay/github-actions/dispatch-pages-deployment@v1` sends the fixed `deploy-pages` repository-dispatch event to a publisher repository. The action accepts only `github-token`, `target-repository`, and `artifact-name`; source repository, workflow run ID, and commit SHA come from the current GitHub Actions context.

```yaml
- uses: SayakMukhopadhyay/github-actions/dispatch-pages-deployment@v1
  with:
    github-token: ${{ secrets.PAGES_PUBLISHER_TOKEN }}
    target-repository: SayakMukhopadhyay/site-publisher
    artifact-name: static-site
```

The fixed client payload contains only `source_repository`, `source_run_id`, `source_sha`, and `artifact_name`. Inputs and context are validated before the API call, transient failures receive bounded retries, and response bodies are never included in failures. The caller owns artifact upload, triggers, conditions, permissions, and the authorization policy for the publisher target.

## `deploy-pages-artifact`

`SayakMukhopadhyay/github-actions/deploy-pages-artifact@v1` is the publisher-side composite. It downloads one named artifact from `source-repository` and `source-run-id`, validates it with `validate-static-site`, configures Pages, packages the validated directory as the GitHub Pages artifact, and deploys it.

```yaml
permissions:
  actions: read
  contents: read
  pages: write
  id-token: write

steps:
  - id: pages
    uses: SayakMukhopadhyay/github-actions/deploy-pages-artifact@v1
    with:
      github-token: ${{ secrets.SOURCE_ARTIFACT_TOKEN }}
      source-repository: ${{ github.event.client_payload.source_repository }}
      source-run-id: ${{ github.event.client_payload.source_run_id }}
      artifact-name: ${{ github.event.client_payload.artifact_name }}
```

Output `page-url` is the deployed Pages URL. The consuming workflow remains responsible for validating and allowlisting dispatch payload values, selecting triggers and jobs, and defining conditions, permissions, environment, concurrency, ordering, and approval gates. This action is not a reusable workflow.

## `azure-acr-token`

`SayakMukhopadhyay/github-actions/azure-acr-token@v1` exchanges GitHub's OIDC identity for a short-lived Azure Container Registry access token. The consuming job must grant `id-token: write`; it retains its triggers, jobs, conditions, environments, concurrency, ordering, and approval gates.

```yaml
permissions:
  contents: read
  id-token: write

steps:
  - id: acr
    uses: SayakMukhopadhyay/github-actions/azure-acr-token@v1
    with:
      client-id: ${{ vars.AZURE_CLIENT_ID }}
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      login-server: ${{ vars.ACR_LOGIN_SERVER }}

  - uses: SayakMukhopadhyay/github-actions/container-build-push@v1
    with:
      registry: ${{ vars.ACR_LOGIN_SERVER }}
      image-repository: andromeda/docs
      username: ${{ steps.acr.outputs.username }}
      password: ${{ steps.acr.outputs.access-token }}
```

`login-server` is the single registry authority. It accepts a conventional host such as `greybodygames.azurecr.io` or a DNL-protected host such as `greybodygames-bkf5agemepdabtg3.azurecr.io`, but rejects schemes, paths, ports, whitespace, and malformed hosts. The action normalizes the host, derives the Azure registry resource name and optional DNL suffix, and calls Azure CLI's suffix-aware `az acr login --expose-token` route without requiring registry configuration-reader access.

Output `username` is the ACR token username `00000000-0000-0000-0000-000000000000`. Output `access-token` is the masked short-lived token. The action never prints the token as ordinary output and fails before publishing outputs if Azure CLI returns an empty token. Client, tenant, and subscription IDs are identifiers; callers should provide them through repository or environment variables and keep workflow permissions narrowly scoped.

## `container-build-push`

`SayakMukhopadhyay/github-actions/container-build-push@v1` builds and optionally publishes exactly one reference, `registry/image-repository[/component]:version`. It forwards optional multiline `build-args`, `build-contexts`, `cache-from`, and `cache-to` inputs unchanged to Docker Buildx and passes the optional `auth-token` input to BuildKit safely. When `push` is true, it logs in normally and inspects that exact reference: an existing reference skips the build and returns its manifest digest, while an absent reference is built and pushed once. When `push` is false, no registry probe occurs and the local build runs as before.

```yaml
- id: image
  uses: SayakMukhopadhyay/github-actions/container-build-push@v1
  with:
    version: build-${{ github.sha }}
    registry: ghcr.io
    image-repository: ${{ github.repository }}
    working-directory: .
    build-args: |
      VERSION=${{ env.VERSION }}
      COMMIT=${{ github.sha }}
    username: ${{ github.actor }}
    password: ${{ github.token }}
```

Outputs are the single normalized `image-reference` and the Buildx `image-digest`. When `push: 'false'`, the build still runs and `image-digest` is empty. Build arguments are not secrets: use `auth-token` for the supported BuildKit secret and never put credentials in `build-args`.

Callers can independently select any Buildx-supported external cache backend. For example, two source-only builds can share content-addressed layers through GitHub Actions cache without sharing generated files or workflow artifacts:

```yaml
cache-from: type=gha,scope=docs
cache-to: type=gha,mode=max,scope=docs
```

Both inputs also accept Docker Buildx's newline-delimited form for multiple cache entries. Values are forwarded verbatim; backend choice, scope naming, export mode, and required workflow permissions remain the caller's responsibility.

For publication, provide `username` and `password` (the password may be `github.token`). GHCR requires `packages: write`. The mandatory push-time check uses Docker's registry-neutral manifest inspection and treats only the standard OCI `MANIFEST_UNKNOWN` and `NAME_UNKNOWN` responses as absent; authentication, network, invalid-reference, and other probe failures fail the action. This is existence-based idempotence, not client-side immutability or race locking; registry policy remains authoritative.

## `container-image-inspect`

`SayakMukhopadhyay/github-actions/container-image-inspect@v1` performs a read-only lookup of exactly one normalized `registry/image-repository[/component]:version` reference. It never builds, pushes, promotes, or tags an image.

```yaml
- id: image
  uses: SayakMukhopadhyay/github-actions/container-image-inspect@v1
  with:
    version: build-${{ github.sha }}
    registry: ghcr.io
    image-repository: ${{ github.repository }}
    username: ${{ github.actor }}
    password: ${{ github.token }}
```

Outputs are `image-reference`, `exists`, and `image-digest`. The digest is a validated `sha256` manifest digest when the exact reference exists and is empty when the registry reports the standard OCI `MANIFEST_UNKNOWN` or `NAME_UNKNOWN` result. Credentials are optional for anonymously readable registries, but `username` and `password` must be provided together. Authentication, transport, malformed manifest metadata, and all other unexpected probe failures fail closed.

## `container-promote`

`SayakMukhopadhyay/github-actions/container-promote@v1` creates one target tag for an already-published image. It constructs `registry/image-repository[/component]@source-digest` and asks Docker Buildx to create `registry/image-repository[/component]:tag` directly from that registry digest. It does not pull or rebuild the image, inspect existing tags, enforce immutability, or verify the result after the registry command succeeds.

```yaml
- uses: SayakMukhopadhyay/github-actions/container-promote@v1
  with:
    source-digest: ${{ needs.publish.outputs.image-digest }}
    tag: v${{ needs.version.outputs.application-version }}
    registry: ghcr.io
    image-repository: ${{ github.repository }}
    username: ${{ github.actor }}
    password: ${{ github.token }}
```

The intended delivery sequence is:

1. `container-build-push` publishes `build-<full SHA>` and returns its digest.
2. Development deploys that build tag and completes its health check.
3. `container-promote` creates `v<VERSION>` from the proven digest.
4. Production deploys the version tag and completes its health check.

Registry authentication failures, rejected tag writes, and other Docker command failures fail the action normally. Registry-side configuration owns tag immutability. GHCR promotion requires `packages: write`; no OIDC permission is requested by either container action.

## `helm-package-push`

`SayakMukhopadhyay/github-actions/helm-package-push@v1` validates the independent chart version authority, builds dependencies, lints, packages in the chart directory, and optionally pushes through Helm OCI. When `push` is true, it logs in normally and asks Helm for the exact OCI chart name and version before starting the transaction. An existing chart skips dependency build, lint, package, and push; an absent chart runs the existing transaction once. When `push` is false, no registry probe occurs and the local Helm transaction runs as before.

```yaml
- id: chart
  uses: SayakMukhopadhyay/github-actions/helm-package-push@v1
  with:
    development: 'true'
    app-version: build-${{ github.sha }}
    registry: ghcr.io
    repository: ${{ github.repository_owner }}/charts
    working-directory: .
    username: ${{ github.actor }}
    password: ${{ github.token }}
```

For development packages, `chart-version` is exactly `0.0.0-build-<full lowercase commit SHA from github.sha>` and is independent of `charts/VERSION`. Stable packages continue to use `charts/VERSION`. For publication, provide `username` and `password`. The mandatory push-time exact-reference check uses Helm's registry-neutral OCI lookup and the same fail-closed standard OCI not-found classification as the container action. Outputs are `chart-name` and `chart-version`.

## `chart-update-deploy`

`SayakMukhopadhyay/github-actions/chart-update-deploy@v1` atomically promotes a Helm dependency version, its image tag, or both in the personal GitOps repository or a caller-selected override.

```yaml
- uses: SayakMukhopadhyay/github-actions/chart-update-deploy@v1
  with:
    token: ${{ steps.app-token.outputs.token }}
    environment: dev
    chart-name: golfs
    chart-version: 0.0.0-build-${{ github.sha }}
    image-tag: build-${{ github.sha }}
```

The preferred `token` is a short-lived GitHub App installation token limited to the target repository with `contents: write`; a repository-limited fine-grained PAT is the fallback. OCI authentication uses `registry`, `username`, and `password`: supplying `registry` requires both credentials, while credentials are rejected when `registry` is empty.

`chart-version` and `image-tag` are independently optional, but at least one is required. By default, the action updates `main` in `SayakMukhopadhyay/k8s-landscape-charts`, derives the wrapper chart path as `<chart-name>/envs/<environment>`, and selects the one dependency whose name or alias matches `chart-name`. `target-repository`, `target-ref`, `wrapper-chart-path`, and `dependency` remain available for repositories whose layout or dependency selector differs. When the dependency has an alias, the alias is the values root; otherwise the dependency name is used.

The default path deliberately follows the BeezLabs first-party convention: each environment owns a complete wrapper chart and may therefore select different dependencies or dependency versions. Existing third-party wrappers that keep `Chart.yaml` directly under `<chart-name>` do not define the first-party pipeline contract; callers targeting one of those layouts must provide `wrapper-chart-path` explicitly.

Supplying `chart-version` changes dependency metadata, `Chart.lock`, and the selected dependency's vendored archives only when the requested version differs. Supplying `image-tag` changes only the explicit `<values-root>.image.tag` in `values.yaml`. When both are supplied, both mutations are committed together. The `commit-sha` output is the pushed GitOps commit, or the current target HEAD for a genuine no-op.

The action stages only the expected wrapper files and uses normal non-force pushes. If the target branch advances concurrently through unrelated files, it refreshes and reapplies the mutation once. A concurrent change to protected wrapper state, a divergent target branch, or a second failed push stops without forcing or overwriting the remote update.

## `argocd-verify-deployment`

> [!WARNING]
> **Temporary bypass:** All operational steps are currently disabled, so the action succeeds without performing verification and does not emit `synchronized-revision`.

`SayakMukhopadhyay/github-actions/argocd-verify-deployment@v1` waits for one Argo CD Application to become `Synced` and `Healthy`, then verifies that the expected GitOps commit is the reported synchronized revision or its Git ancestor. It uses Argo CD through gRPC-web and sends the supplied Cloudflare Access service-token headers on every Argo request.

```yaml
- id: deployment
  uses: SayakMukhopadhyay/github-actions/argocd-verify-deployment@v1
  with:
    server: argocd.example.com
    application: golfs-production
    auth-token: ${{ secrets.ARGOCD_AUTH_TOKEN }}
    cloudflare-access-client-id: ${{ secrets.CF_ACCESS_CLIENT_ID }}
    cloudflare-access-client-secret: ${{ secrets.CF_ACCESS_CLIENT_SECRET }}
    expected-commit-sha: ${{ needs.promote.outputs.commit-sha }}
    gitops-repository: SayakMukhopadhyay/k8s-landscape-charts
    gitops-token: ${{ secrets.GITOPS_READ_TOKEN }}
    timeout-seconds: '300'
    smoke-url: https://golfs.example.com/health
```

The optional `smoke-url` receives the same Cloudflare Access headers and must return without an HTTP or network error. The action exposes `synchronized-revision`, supports Linux x64 runners, and installs Argo CD CLI `v3.5.2` from its versioned release URL only after verifying the pinned SHA-256 checksum. It is strictly read-only: it does not sync or refresh Argo CD, mutate GitOps state, commit, push, deploy, or access the cluster directly.

## `static-site-update-deploy`

`SayakMukhopadhyay/github-actions/static-site-update-deploy@v1` promotes a static-site container image through its environment wrapper chart.

```yaml
- uses: SayakMukhopadhyay/github-actions/static-site-update-deploy@v1
  with:
    token: ${{ steps.app-token.outputs.token }}
    environment: production
    chart-name: landscape
    image-version: build-${{ github.sha }}
```

By default, the action updates `main` in `SayakMukhopadhyay/k8s-landscape-charts` and derives the wrapper chart path as `<chart-name>/envs/<environment>`. `target-repository`, `target-ref`, and `wrapper-chart-path` remain available for repositories whose location or layout differs.

The wrapper must contain exactly one dependency named `static-sites`, aliased as `staticSites`, and its `values.yaml` must already contain a string at `staticSites.image.tag`. The action updates only that value, always runs `helm lint` including for a no-op, stages only `values.yaml`, and treats an already-current tag as success. It uses the shared GitOps transaction's normal non-force push behavior: one unrelated concurrent update is refreshed and reapplied, while protected-state changes, divergent history, and a second failed push stop without overwriting the remote. It never changes or downloads the fixed `static-sites` dependency.

## `release-tags`

`SayakMukhopadhyay/github-actions/release-tags@v1` checks for, verifies, or ensures a caller-selected set of release tags. The read-only `exists` mode reports through `tags-exist` whether every requested tag exists, regardless of its target. The default `verify` mode reports through `tags-match` whether they all resolve to the exact caller commit, `${{ github.sha }}`. `ensure` requires `contents: write` and creates only missing lightweight tags.

Use `exists` when release orchestration needs to distinguish a previously published tag from a release that has not started:

```yaml
permissions:
  contents: read

steps:
  - id: release-tag
    uses: SayakMukhopadhyay/github-actions/release-tags@v1
    with:
      token: ${{ github.token }}
      mode: exists
      tags: v${{ needs.version.outputs.application-version }}

  - if: steps.release-tag.outputs.tags-exist == 'false'
    # Start the release path that creates the tag.
    shell: pwsh
    run: ./start-release.ps1
```

```yaml
permissions:
  contents: write

steps:
  - id: tags
    uses: SayakMukhopadhyay/github-actions/release-tags@v1
    with:
      token: ${{ github.token }}
      mode: ensure
      tags: |
        v${{ needs.version.outputs.application-version }}
        charts/v${{ needs.version.outputs.chart-version }}
```

Inputs are required `token`, required newline-delimited `tags`, and optional `mode`, which accepts `exists`, `verify`, or `ensure` and defaults to `verify`. In `exists` mode, output `tags-exist` is `true` only when every requested tag exists; lightweight and annotated tags both count, and their target commits do not matter. In `verify` and `ensure` modes, the existing `tags-match` output is `true` only when every requested tag exists and resolves to `${{ github.sha }}`. The two outputs are mode-specific, so the unused output is an empty string rather than a second interpretation of the result.

Existence and verification report missing or mismatched tags without changing the repository. Ensure mode validates the complete tag list first, rejects duplicates, invalid names, and tags resolving elsewhere, then pushes every missing ref in one atomic non-force operation. It re-verifies the remote after the push, so retries and concurrent same-target creation are idempotent while a competing target fails closed.

The checkout and remote Git operations receive `token` without persisting credentials. The caller still owns events, jobs, conditions, permissions, environments, concurrency, release ordering, approval gates, and the decision to verify or create application and chart tags.

## `create-release`

`SayakMukhopadhyay/github-actions/create-release@v1` combines explicit PowerShell boundaries for local Git context and GitHub publication with a bundled TypeScript release-note generator. The action targets the current `github.repository` and has exactly four required inputs: `token`, `tag-name`, `release-name`, and `openai-api-key`.

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

Optional `pathspecs` scopes release context with newline-delimited native Git pathspecs. Every non-empty line is passed unchanged as one argument after Git's `--` separator; a trailing newline and CRLF input are accepted, while an internal empty line, the special `:` no-pathspec sentinel, or invalid pathspec magic fails closed. Omitting `pathspecs` or passing an empty value preserves the unscoped behavior above.

For GOLFS, chart releases can include only the chart tree:

```yaml
pathspecs: |
  :(top,glob)charts/**
```

Application releases can start with the complete repository and exclude that tree:

```yaml
pathspecs: |
  :(top,glob)**
  :(top,glob,exclude)charts/**
```

The same pathspec array selects first-parent commits in the release range and filters the changed-file statistics and patch collected for each selected commit. A commit that changes both application and chart files is therefore eligible for both releases, but each invocation exposes only its matching file evidence to the model.

The action sends bounded selected commit subjects, scoped per-commit changed-file statistics, and scoped size-limited patches to the OpenAI Responses API as explicitly untrusted repository data. It pins `gpt-5.6-luna`, disables storage, supplies no tools, requests a strict JSON schema, and validates the returned plain-text description and highlights before composing Markdown. OpenAI never supplies tags, versions, commit entries, artifact references, or links. An unavailable, refused, incomplete, malformed, or unsafe AI response fails before GitHub Release creation.

Outputs are `release-id`, `html-url`, and `upload-url`, corresponding to the useful ID, HTML URL, and upload URL values exposed by the legacy action.

The checkout sees only the GitHub token. The collector receives no secrets. The generator receives only the OpenAI key and secret-free context. The publisher receives only the GitHub token and the locally validated release body. No process receives both credentials.

The caller retains events, jobs, `needs`, conditions, permissions, environments, concurrency, publication ordering, approval gates, and the decision to run application and chart releases independently. This action owns only tag verification, family/range derivation, bounded note generation, deterministic Markdown composition, idempotency, and Release creation.

## Consumer workflow schema

Editors can combine SchemaStore's GitHub workflow completion with this repository's generated action-input contracts by placing this comment at the top of a workflow:

```yaml
# $schema: https://raw.githubusercontent.com/SayakMukhopadhyay/github-actions/v1/schemas/github-workflow.schema.json
```

The wrapper references SchemaStore's live workflow schema and the committed `schemas/action-inputs.schema.json` overlay. The overlay is generated from every root-level reusable `action.yaml` file, which remains the sole input authority. It validates inputs for this repository's `@v1` action paths; it does not attempt to interpret output names embedded in GitHub expressions.

## Development

The repository is one npm package and does not use workspaces. JavaScript actions keep their TypeScript entry point, `action.yaml`, and generated `dist/index.mjs` together; maintained command transactions use PowerShell 7.4 or newer:

- `check-version/`, `validate-static-site/`, and `dispatch-pages-deployment/` are directly callable as JavaScript actions.
- `actions/argocd-verify-deployment/`, `actions/bump-version/`, `actions/create-release/`, `actions/helm-package-push/`, and `actions/is-file-changed/` are private implementation actions invoked by their root-level composite wrappers.
- `tooling/` contains repository-maintenance programs such as schema generation.

`powershell/ActionRuntime.psm1` is intentionally narrow: native process execution, GitHub workflow protocol helpers, single-line validation, and contained temporary cleanup. `ContainerImage.psm1` owns normalized image names plus tag and digest references, `RegistryCredentials.psm1` owns the shared credential policy, `OciArtifactProbe.psm1` owns fail-closed artifact existence classification, and `GitOpsChartUpdate.psm1` owns the chart mutation, lint, commit, and safe retry transaction. Action-local modules remain thin adapters where family-specific inputs or messages differ.

Install the exact locked Node dependencies, pinned PowerShell modules, and verified native tools with Node `24.20.0` and PowerShell 7.4 or newer:

```powershell
npm run bootstrap
```

Node.js development tasks are owned by npm:

```powershell
npm run format:check
npm run lint
npm run typecheck
npm test
npm run generate
npm run build
npm run validate:node
```

`build.ps1` owns only PowerShell and native-tool work. Its `Format`, `FormatCheck`, `Lint`, `Test`, and `Validate` tasks cover PowerShell formatting, PSScriptAnalyzer, Pester, repository shell policy, actionlint, and Git whitespace checks. Run the complete repository validation through npm:

```powershell
npm run validate
```

Bootstrap remains explicit; validation never silently downloads dependencies or tools.

TypeScript in this repository—production actions, tooling, and tests—must never spawn an external process. It may parse files and use JavaScript facilities such as the `RegExp` constructor. Git, Helm, `yq`, and GitHub CLI transactions belong in checked PowerShell modules or composite steps. Pester tests invoke those command boundaries directly and use real temporary Git repositories where transaction behavior matters.

Node and Pester tests are hermetic and credential-free. They use temporary repositories, local charts, mocks, injected OpenAI clients, and captured GitHub output files. They never publish a container or chart, mutate a live remote, create a GitHub Release, call OpenAI, or contact a cluster.

## Generated artifacts

TypeScript sources, public and implementation metadata, ESM bundles, external source maps, generated schemas, package metadata, and the npm lockfile are committed together. After changing source or metadata, regenerate the affected artifacts and inspect the exact diff:

```powershell
npm run generate
npm run build
git diff --check
```

CI repeats schema generation and bundling through npm and rejects any byte-level drift. Fixed output names and LF normalization keep the committed artifacts reproducible across Windows development and Ubuntu CI. Do not submit source-only changes expecting a later release build to update `dist`.

Licensed dependency metadata lives under `.licenses/npm` and is governed by `.licensed.yml`. When npm dependencies change, run `licensed cache` with Licensed `5.1.0`, review the generated records, and commit them with the lockfile. CI runs `licensed status`; it never updates or commits the cache.

## CI and v1 promotion

Windows and Ubuntu CI run the complete npm and PowerShell validation suites, including TypeScript, ESLint, Prettier, PSScriptAnalyzer, Node tests, Pester, typechecking, schema generation, bundling, generated-artifact drift checks, and actionlint. Ubuntu also runs offline Zizmor, Licensed, security policy, and credential-free action fixtures. External actions use reviewed full commit SHAs. Dependabot opens weekly npm and GitHub Actions pull requests; updates are never automerged.

Source changes do not move `v1`. To promote or intentionally roll back, manually run the **Promote v1** workflow with a full 40-character commit SHA from `main`. It verifies that exact commit is reachable from `main`, then moves the lightweight `v1` tag with force-with-lease protection. The promotion job alone receives `contents: write`; no semver tag or GitHub Release is created for this action repository.

Local development and ordinary CI perform no remote publication, create no live GitHub Release, and never move the `v1` tag.

Copyright 2026 Sayak Mukhopadhyay. All rights reserved. No license is granted for use, modification, or distribution.
