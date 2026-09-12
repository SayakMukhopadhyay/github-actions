import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { parse } from 'yaml';

interface ActionInput {
  default?: unknown;
  description?: unknown;
  required?: unknown;
}

interface ActionOutput {
  description?: unknown;
  value?: unknown;
}

interface ActionStep {
  env?: Record<string, unknown>;
  id?: unknown;
  if?: unknown;
  name?: unknown;
  run?: unknown;
  shell?: unknown;
  uses?: unknown;
  with?: Record<string, unknown>;
  'working-directory'?: unknown;
}

interface ActionMetadata {
  inputs?: Record<string, ActionInput>;
  outputs?: Record<string, ActionOutput>;
  runs?: {
    main?: unknown;
    steps?: ActionStep[];
    using?: unknown;
  };
}

interface WorkflowStep {
  uses?: unknown;
  with?: Record<string, unknown>;
}

interface WorkflowMetadata {
  jobs?: Record<string, { steps?: WorkflowStep[] }>;
}

const root = path.resolve(import.meta.dirname, '..');
const immutableAction = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[0-9a-f]{40}$/u;
const internalAction = /^\$\/(?:actions\/)?[a-z0-9-]+$/u;

function readYaml<T>(file: string): T {
  return parse(readFileSync(file, 'utf8')) as T;
}

function readAction(name: string): ActionMetadata {
  return readYaml<ActionMetadata>(path.join(root, name, 'action.yaml'));
}

function consumerActionNames(): string[] {
  return readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .filter((entry) => {
      try {
        return readFileSync(path.join(root, entry.name, 'action.yaml')).length > 0;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
          return false;
        }
        throw error;
      }
    })
    .map((entry) => entry.name)
    .sort((left, right) => left.localeCompare(right));
}

void test('consumer action metadata is complete and uses safe runtime boundaries', () => {
  const actionNames = consumerActionNames();

  assert.notEqual(actionNames.length, 0, 'expected at least one reusable action');

  const readme = readFileSync(path.join(root, 'README.md'), 'utf8');

  for (const actionName of actionNames) {
    const metadata = readAction(actionName);

    assert.equal(
      metadata.runs?.using === 'node24' || metadata.runs?.using === 'composite',
      true,
      `${actionName} runtime`,
    );
    if (metadata.runs?.using === 'node24') {
      assert.equal(metadata.runs?.main, 'dist/index.mjs', `${actionName} bundle entry`);
    }

    for (const [inputName, input] of Object.entries(metadata.inputs ?? {})) {
      assert.equal(typeof input.description, 'string', `${actionName}.${inputName} description`);
      assert.notEqual(input.description, '', `${actionName}.${inputName} description`);
      assert.equal(typeof input.required, 'boolean', `${actionName}.${inputName} required`);
    }

    for (const [outputName, output] of Object.entries(metadata.outputs ?? {})) {
      assert.equal(typeof output.description, 'string', `${actionName}.${outputName} description`);
      assert.notEqual(output.description, '', `${actionName}.${outputName} description`);
      assert.equal(typeof output.value, 'string', `${actionName}.${outputName} value`);
      assert.notEqual(output.value, '', `${actionName}.${outputName} value`);
    }

    assert.match(
      readme,
      new RegExp(`SayakMukhopadhyay/github-actions/${actionName}@v1`, 'u'),
      `${actionName} README reference`,
    );

    for (const step of metadata.runs?.steps ?? []) {
      if (typeof step.uses === 'string') {
        assert.equal(
          immutableAction.test(step.uses) || internalAction.test(step.uses),
          true,
          `${actionName} action reference is not immutable or repository-internal: ${step.uses}`,
        );
      }

      if (step.run !== undefined) {
        assert.equal(typeof step.shell, 'string', `${actionName} run step needs an explicit shell`);
        assert.notEqual(step.shell, '', `${actionName} run step needs an explicit shell`);
      }
    }
  }
});

void test('container build metadata keeps one version tag, exact forwarding, and push-only digest output', () => {
  const metadata = readAction('container-build-push');

  for (const input of ['build-contexts', 'build-args', 'cache-from', 'cache-to']) {
    assert.equal(metadata.inputs?.[input]?.required, false, `${input} is optional`);
    assert.equal(metadata.inputs?.[input]?.default, '', `${input} has an empty default`);
  }

  const buildSteps = (metadata.runs?.steps ?? []).filter(
    (step) => typeof step.uses === 'string' && step.uses.startsWith('docker/build-push-action@'),
  );
  assert.equal(buildSteps.length, 1);
  assert.equal(buildSteps[0]?.with?.['build-contexts'], '${{ inputs.build-contexts }}');
  assert.equal(buildSteps[0]?.with?.['build-args'], '${{ inputs.build-args }}');
  assert.equal(buildSteps[0]?.with?.['cache-from'], '${{ inputs.cache-from }}');
  assert.equal(buildSteps[0]?.with?.['cache-to'], '${{ inputs.cache-to }}');
  assert.equal(buildSteps[0]?.with?.tags, '${{ steps.prepare.outputs.image-reference }}');
  assert.equal(buildSteps[0]?.if, "inputs.push != 'true' || steps.probe.outputs.exists != 'true'");

  assert.equal(metadata.inputs?.version?.required, true);
  assert.equal('mode' in (metadata.inputs ?? {}), false);
  assert.equal('tags' in (metadata.inputs ?? {}), false);
  assert.equal('source-reference' in (metadata.inputs ?? {}), false);
  assert.equal(metadata.outputs?.['image-reference']?.value, '${{ steps.prepare.outputs.image-reference }}');
  assert.equal(
    metadata.outputs?.['image-digest']?.value,
    "${{ inputs.push == 'true' && (steps.probe.outputs.image-digest || steps.build.outputs.digest) || '' }}",
  );
  assert.deepEqual(Object.keys(metadata.outputs ?? {}).sort(), ['image-digest', 'image-reference']);

  const probe = (metadata.runs?.steps ?? []).find((step) => step.id === 'probe');
  assert.equal(probe?.if, "inputs.push == 'true'");
  assert.equal(probe?.env?.IMAGE_REFERENCE, '${{ steps.prepare.outputs.image-reference }}');
  assert.match(String(probe?.run), /probe-image\.ps1/u);
});

void test('container image inspection metadata is exact-reference and read-only', () => {
  const metadata = readAction('container-image-inspect');

  assert.deepEqual(Object.keys(metadata.inputs ?? {}).sort(), [
    'component',
    'image-repository',
    'password',
    'registry',
    'username',
    'version',
  ]);
  assert.equal(metadata.inputs?.version?.required, true);
  assert.equal(metadata.inputs?.registry?.default, 'ghcr.io');
  assert.equal(metadata.inputs?.['image-repository']?.default, '');
  assert.deepEqual(Object.keys(metadata.outputs ?? {}).sort(), ['exists', 'image-digest', 'image-reference']);
  assert.equal(metadata.outputs?.['image-reference']?.value, '${{ steps.prepare.outputs.image-reference }}');
  assert.equal(metadata.outputs?.exists?.value, '${{ steps.inspect.outputs.exists }}');
  assert.equal(metadata.outputs?.['image-digest']?.value, '${{ steps.inspect.outputs.image-digest }}');

  const steps = metadata.runs?.steps ?? [];
  assert.equal(
    steps.some((step) => String(step.uses).startsWith('docker/build-push-action@')),
    false,
  );
  assert.equal(
    steps.some((step) => /build|push|promote|tag/u.test(String(step.run))),
    false,
  );

  const buildx = steps.filter((step) => String(step.uses).startsWith('docker/setup-buildx-action@'));
  assert.equal(buildx.length, 1);

  const login = steps.find((step) => String(step.uses).startsWith('docker/login-action@'));
  assert.equal(login?.if, "inputs.username != '' || inputs.password != ''");
  assert.equal(login?.with?.registry, '${{ inputs.registry }}');
  assert.equal(login?.with?.username, '${{ inputs.username }}');
  assert.equal(login?.with?.password, '${{ inputs.password }}');

  const inspect = steps.find((step) => step.id === 'inspect');
  assert.equal(inspect?.env?.IMAGE_REFERENCE, '${{ steps.prepare.outputs.image-reference }}');
  assert.match(String(inspect?.run), /inspect-image\.ps1/u);
});

void test('Helm package metadata keeps development source authority private', () => {
  const metadata = readAction('helm-package-push');

  assert.equal('source-revision' in (metadata.inputs ?? {}), false);

  const preparation = (metadata.runs?.steps ?? []).find((step) => step.id === 'prepare');
  assert.equal(preparation?.uses, '$/actions/helm-package-push');
  assert.equal(preparation?.with?.['source-revision'], '${{ github.sha }}');

  const internalPreparation = readAction('actions/helm-package-push');
  assert.equal(internalPreparation.inputs?.['source-revision']?.required, true);
});

void test('container promotion metadata performs one direct digest-to-tag operation', () => {
  const metadata = readAction('container-promote');

  assert.equal(metadata.inputs?.['source-digest']?.required, true);
  assert.equal(metadata.inputs?.tag?.required, true);
  assert.deepEqual(Object.keys(metadata.inputs ?? {}).sort(), [
    'component',
    'image-repository',
    'password',
    'registry',
    'source-digest',
    'tag',
    'username',
  ]);

  const steps = metadata.runs?.steps ?? [];

  assert.equal(
    steps.some((step) => String(step.uses).startsWith('docker/build-push-action@')),
    false,
  );
  assert.equal(
    steps.some((step) => String(step.uses).startsWith('actions/checkout@')),
    false,
  );
  const command = steps.find((step) => step.name === 'Create target image tag')?.run;

  assert.match(String(command), /promote\.ps1/u);

  const promotionModule = readFileSync(
    path.join(import.meta.dirname, '..', 'container-promote', 'ContainerPromotion.psm1'),
    'utf8',
  );

  assert.match(promotionModule, /'buildx',\s*'imagetools',\s*'create',\s*'--prefer-index=false'/u);
  assert.doesNotMatch(promotionModule, /imagetools['"]?,['"]?inspect|docker pull|docker (?:image )?build(?: |$)/u);
});

void test('registry credential policy is wired before every registry login', () => {
  const build = readAction('container-build-push');
  const buildSteps = build.runs?.steps ?? [];
  const buildPrepare = buildSteps.find((step) => step.id === 'prepare');
  const buildLoginIndex = buildSteps.findIndex((step) => String(step.uses).startsWith('docker/login-action@'));
  assert.equal(buildPrepare?.env?.INPUT_PUSH, '${{ inputs.push }}');
  assert.equal(buildPrepare?.env?.INPUT_USERNAME, '${{ inputs.username }}');
  assert.equal(buildPrepare?.env?.INPUT_PASSWORD, '${{ inputs.password }}');
  assert.ok(buildSteps.indexOf(buildPrepare) < buildLoginIndex);

  const inspection = readAction('container-image-inspect');
  const inspectionSteps = inspection.runs?.steps ?? [];
  assert.ok(
    inspectionSteps.findIndex((step) => step.id === 'prepare') <
      inspectionSteps.findIndex((step) => String(step.uses).startsWith('docker/login-action@')),
  );

  const promotion = readAction('container-promote');
  const promotionSteps = promotion.runs?.steps ?? [];
  const promotionPrepare = promotionSteps.find((step) => step.id === 'prepare');
  const promotionModule = readFileSync(path.join(root, 'container-promote', 'ContainerPromotion.psm1'), 'utf8');
  assert.equal(promotionPrepare?.env?.INPUT_USERNAME, '${{ inputs.username }}');
  assert.equal(promotionPrepare?.env?.INPUT_PASSWORD, '${{ inputs.password }}');
  assert.ok(
    promotionSteps.indexOf(promotionPrepare) <
      promotionSteps.findIndex((step) => String(step.uses).startsWith('docker/login-action@')),
  );

  for (const [actionName, requirement] of [
    ['helm-package-push', "${{ inputs.push == 'true' && 'Required' || 'Optional' }}"],
    ['chart-update-deploy', "${{ inputs.registry != '' && 'Required' || 'Forbidden' }}"],
  ] as const) {
    const metadata = readAction(actionName);
    const steps = metadata.runs?.steps ?? [];
    const validationIndex = steps.findIndex((step) => step.name === 'Validate registry credentials');
    const loginIndex = steps.findIndex((step) => step.name === 'Log in to OCI registry');
    const validation = steps[validationIndex];

    assert.notEqual(validationIndex, -1, `${actionName} credential validation step`);
    assert.ok(validationIndex < loginIndex, `${actionName} validates before login`);
    assert.equal(validation?.env?.REGISTRY_CREDENTIAL_REQUIREMENT, requirement);
    assert.equal(validation?.env?.INPUT_USERNAME, '${{ inputs.username }}');
    assert.equal(validation?.env?.INPUT_PASSWORD, '${{ inputs.password }}');
    assert.match(String(validation?.run), /validate-registry-credentials\.ps1/u);
  }

  const buildModule = readFileSync(path.join(root, 'container-build-push', 'ContainerBuild.psm1'), 'utf8');
  assert.match(buildModule, /INPUT_PUSH -eq 'true'.+?'Required'.+?'Optional'/su);
  assert.ok(buildModule.indexOf('Assert-RegistryCredentials') < buildModule.indexOf('Resolve-ContainerImageReference'));

  const inspectionModule = readFileSync(
    path.join(root, 'container-image-inspect', 'ContainerImageInspect.psm1'),
    'utf8',
  );
  assert.match(inspectionModule, /Assert-RegistryCredentials[\s\S]+?-Requirement Optional/u);

  assert.match(promotionModule, /Assert-RegistryCredentials[\s\S]+?-Requirement Required/u);
  assert.ok(
    promotionModule.indexOf('Assert-RegistryCredentials') < promotionModule.indexOf('Resolve-ContainerImageName'),
  );
  assert.match(promotionModule, /New-ContainerDigestReference/u);
  assert.match(promotionModule, /New-ContainerTagReference/u);
  assert.doesNotMatch(promotionModule, /registryPattern|pathPattern/u);
});

void test('action families use shared coordinates, OCI probing, and GitOps transactions', () => {
  for (const actionName of ['container-build-push', 'container-image-inspect', 'container-promote']) {
    const metadata = readAction(actionName);

    assert.equal(metadata.inputs?.component?.default, '', `${actionName} component default`);
    assert.equal(metadata.inputs?.registry?.default, 'ghcr.io', `${actionName} registry default`);
    assert.equal(metadata.inputs?.['image-repository']?.default, '', `${actionName} repository default`);
  }

  const containerImage = readFileSync(path.join(root, 'powershell', 'ContainerImage.psm1'), 'utf8');
  assert.match(containerImage, /function Resolve-ContainerImageName/u);
  assert.match(containerImage, /function New-ContainerTagReference/u);
  assert.match(containerImage, /function New-ContainerDigestReference/u);
  assert.match(containerImage, /Invoke-OciArtifactProbe docker/u);

  const helmTransaction = readFileSync(path.join(root, 'helm-package-push', 'HelmTransaction.psm1'), 'utf8');
  assert.match(helmTransaction, /Import-Module.+OciArtifactProbe\.psm1/u);
  assert.match(helmTransaction, /Invoke-OciArtifactProbe helm/u);

  for (const adapter of [
    path.join(root, 'chart-update-deploy', 'ChartUpdate.psm1'),
    path.join(root, 'static-site-update-deploy', 'StaticSiteUpdate.psm1'),
  ]) {
    const source = readFileSync(adapter, 'utf8');

    assert.match(source, /Import-Module.+GitOpsChartUpdate\.psm1/u);
    assert.match(source, /Invoke-GitOpsChartUpdate/u);
    assert.doesNotMatch(source, /function Assert-ContainedPath|function Invoke-WrapperMutation/u);
  }
});

void test('registry-aware action metadata uses consistent grouping and credential language', () => {
  const expectedInputOrder: Record<string, string[]> = {
    'container-build-push': [
      'version',
      'registry',
      'image-repository',
      'component',
      'push',
      'username',
      'password',
      'working-directory',
      'auth-token',
      'build-contexts',
      'build-args',
      'cache-from',
      'cache-to',
    ],
    'container-image-inspect': ['version', 'registry', 'image-repository', 'component', 'username', 'password'],
    'container-promote': ['source-digest', 'tag', 'registry', 'image-repository', 'component', 'username', 'password'],
    'helm-package-push': [
      'development',
      'app-version',
      'registry',
      'repository',
      'push',
      'username',
      'password',
      'working-directory',
    ],
    'chart-update-deploy': [
      'token',
      'environment',
      'chart-name',
      'chart-version',
      'image-tag',
      'dependency',
      'target-repository',
      'target-ref',
      'wrapper-chart-path',
      'registry',
      'username',
      'password',
    ],
  };

  for (const [actionName, inputOrder] of Object.entries(expectedInputOrder)) {
    assert.deepEqual(Object.keys(readAction(actionName).inputs ?? {}), inputOrder, `${actionName} input grouping`);
  }

  const build = readAction('container-build-push');
  const inspect = readAction('container-image-inspect');
  const promote = readAction('container-promote');
  const helm = readAction('helm-package-push');
  const chart = readAction('chart-update-deploy');

  for (const metadata of [build, inspect, promote]) {
    assert.equal(metadata.inputs?.registry?.description, 'OCI registry host');
    assert.equal(
      metadata.inputs?.['image-repository']?.description,
      'Image repository below the registry; defaults to github.repository',
    );
    assert.equal(metadata.inputs?.component?.description, 'Optional component appended to the image repository');
  }

  assert.equal(
    build.inputs?.username?.description,
    'Registry username; required with password when push is true, otherwise optional only as a complete pair',
  );
  assert.equal(
    build.inputs?.password?.description,
    'Registry password or token; required with username when push is true, otherwise optional only as a complete pair',
  );
  assert.equal(
    inspect.inputs?.username?.description,
    'Optional registry username; must be provided together with password',
  );
  assert.equal(
    inspect.inputs?.password?.description,
    'Optional registry password or token; must be provided together with username',
  );
  assert.equal(promote.inputs?.username?.description, 'Registry username; required together with password');
  assert.equal(promote.inputs?.password?.description, 'Registry password or token; required together with username');
  assert.equal(promote.inputs?.username?.required, true);
  assert.equal(promote.inputs?.password?.required, true);

  assert.equal(helm.inputs?.registry?.description, 'OCI registry host');
  assert.equal(
    helm.inputs?.repository?.description,
    'Chart repository below the registry; defaults to github.repository_owner/charts',
  );
  assert.equal(helm.inputs?.username?.description, build.inputs?.username?.description);
  assert.equal(helm.inputs?.password?.description, build.inputs?.password?.description);

  assert.equal(
    chart.inputs?.registry?.description,
    'Optional OCI registry host; credentials are required when provided',
  );
  assert.equal(
    chart.inputs?.username?.description,
    'OCI registry username; required with password when registry is provided and forbidden otherwise',
  );
  assert.equal(
    chart.inputs?.password?.description,
    'OCI registry password or token; required with username when registry is provided and forbidden otherwise',
  );
});

void test('Azure ACR token metadata keeps OIDC inputs, token outputs, and the immutable login pin explicit', () => {
  const metadata = readAction('azure-acr-token');

  assert.deepEqual(Object.keys(metadata.inputs ?? {}).sort(), [
    'client-id',
    'login-server',
    'subscription-id',
    'tenant-id',
  ]);
  for (const input of Object.values(metadata.inputs ?? {})) {
    assert.equal(input.required, true);
  }

  assert.equal(metadata.outputs?.username?.value, '${{ steps.token.outputs.username }}');
  assert.equal(metadata.outputs?.['access-token']?.value, '${{ steps.token.outputs.access-token }}');

  const steps = metadata.runs?.steps ?? [];

  assert.equal(steps.length, 2);
  assert.equal(steps[0]?.uses, 'azure/login@7ddb5af1ef8758cf1353cf3b42f940aee27ba21c');
  assert.deepEqual(steps[0]?.with, {
    'client-id': '${{ inputs.client-id }}',
    'tenant-id': '${{ inputs.tenant-id }}',
    'subscription-id': '${{ inputs.subscription-id }}',
  });
  assert.equal(steps[1]?.id, 'token');
  assert.equal(steps[1]?.env?.INPUT_LOGIN_SERVER, '${{ inputs.login-server }}');
  assert.equal(steps[1]?.shell, 'pwsh');
  assert.match(String(steps[1]?.run), /azure-acr-token\.ps1/u);

  const transaction = readFileSync(path.join(root, 'azure-acr-token', 'AzureAcrToken.psm1'), 'utf8');

  assert.match(transaction, /--suffix/u);
  assert.match(transaction, /Add-GitHubMask/u);
  assert.match(transaction, /Write-GitHubOutput.+access-token/su);
});

void test('checkout-dependencies supports explicit Go and npm selection with one secure checkout', () => {
  const metadata = readAction('checkout-dependencies');

  assert.equal(metadata.inputs?.['working-directory']?.default, '.');
  assert.equal(metadata.inputs?.['go-version']?.required, false);
  assert.equal(metadata.inputs?.['go-version']?.default, '');
  assert.equal(metadata.inputs?.['go-working-directory']?.default, '');
  assert.equal(metadata.inputs?.['node-version']?.default, '');
  assert.equal(metadata.inputs?.['node-version-file']?.default, '');
  assert.equal(metadata.inputs?.['node-working-directory']?.default, '');

  const steps = metadata.runs?.steps ?? [];
  const checkoutSteps = steps.filter(
    (step) => typeof step.uses === 'string' && step.uses.startsWith('actions/checkout@'),
  );

  assert.equal(checkoutSteps.length, 1);
  assert.equal(checkoutSteps[0]?.with?.['persist-credentials'], false);

  const setupNode = steps.find((step) => typeof step.uses === 'string' && step.uses.startsWith('actions/setup-node@'));

  assert.equal(setupNode?.with?.cache, 'npm');
  assert.match(String(setupNode?.with?.['cache-dependency-path']), /package-lock\.json/u);
  assert.equal('cache-dependency-path' in (metadata.inputs ?? {}), false);

  const npmInstall = steps.find((step) => step.run === 'npm ci');

  assert.notEqual(npmInstall, undefined);
  assert.match(String(npmInstall?.['working-directory']), /node-working-directory/u);
});

void test('Pages deployment metadata keeps dispatch and publication contracts narrow', () => {
  const dispatch = readAction('dispatch-pages-deployment');

  assert.deepEqual(Object.keys(dispatch.inputs ?? {}).sort(), ['artifact-name', 'github-token', 'target-repository']);

  const deploy = readAction('deploy-pages-artifact');

  assert.deepEqual(Object.keys(deploy.inputs ?? {}).sort(), [
    'artifact-name',
    'github-token',
    'source-repository',
    'source-run-id',
  ]);
  assert.equal(deploy.outputs?.['page-url']?.value, '${{ steps.deployment.outputs.page_url }}');

  const steps = deploy.runs?.steps ?? [];

  assert.deepEqual(
    steps.map((step) => step.uses),
    [
      'actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131',
      '$/validate-static-site',
      'actions/configure-pages@45bfe0192ca1faeb007ade9deae92b16b8254a0d',
      'actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9',
      'actions/deploy-pages@368f82528645a54fb793d4d04e342629a3f51346',
    ],
  );
});

void test('chart promotion metadata exposes personal defaults with explicit overrides', () => {
  const metadata = readAction('chart-update-deploy');

  assert.equal(metadata.inputs?.['chart-version']?.required, false);
  assert.equal(metadata.inputs?.['chart-version']?.default, '');
  assert.equal(metadata.inputs?.['image-tag']?.required, false);
  assert.equal(metadata.inputs?.['image-tag']?.default, '');
  assert.equal(metadata.inputs?.dependency?.required, false);
  assert.equal(metadata.inputs?.dependency?.default, '');
  assert.equal(metadata.inputs?.['target-repository']?.required, false);
  assert.equal(metadata.inputs?.['target-repository']?.default, 'SayakMukhopadhyay/k8s-landscape-charts');
  assert.equal(metadata.inputs?.['target-ref']?.default, 'main');
  assert.equal(metadata.inputs?.['wrapper-chart-path']?.default, '');
  assert.equal(metadata.outputs?.['commit-sha']?.value, '${{ steps.update.outputs.commit-sha }}');
});

void test('static-site promotion metadata keeps the fixed dependency contract narrow', () => {
  const metadata = readAction('static-site-update-deploy');

  assert.deepEqual(Object.keys(metadata.inputs ?? {}).sort(), [
    'chart-name',
    'environment',
    'image-version',
    'target-ref',
    'target-repository',
    'token',
    'wrapper-chart-path',
  ]);
  assert.equal(metadata.inputs?.['target-repository']?.default, 'SayakMukhopadhyay/k8s-landscape-charts');
  assert.equal(metadata.inputs?.['target-ref']?.default, 'main');
  assert.equal(metadata.inputs?.['wrapper-chart-path']?.default, '');
});

void test('release-tags fixes the target and keeps Git credentials ephemeral', () => {
  const metadata = readAction('release-tags');

  assert.equal(metadata.inputs?.token?.required, true);
  assert.equal(metadata.inputs?.tags?.required, true);
  assert.equal(metadata.inputs?.mode?.default, 'verify');
  assert.match(String(metadata.inputs?.mode?.description), /\bexists\b/u);
  assert.equal(metadata.outputs?.['tags-exist']?.value, '${{ steps.tags.outputs.tags-exist }}');
  assert.match(String(metadata.outputs?.['tags-exist']?.description), /every requested tag exists/u);
  assert.equal(metadata.outputs?.['tags-match']?.value, '${{ steps.tags.outputs.tags-match }}');
  assert.match(String(metadata.outputs?.['tags-match']?.description), /verify or ensure mode/u);

  const checkoutSteps = (metadata.runs?.steps ?? []).filter(
    (step) => typeof step.uses === 'string' && step.uses.startsWith('actions/checkout@'),
  );

  assert.equal(checkoutSteps.length, 1);
  assert.equal(checkoutSteps[0]?.with?.ref, '${{ github.sha }}');
  assert.equal(checkoutSteps[0]?.with?.['fetch-tags'], false);
  assert.equal(checkoutSteps[0]?.with?.['persist-credentials'], false);

  const transactionSteps = (metadata.runs?.steps ?? []).filter((step) => step.id === 'tags');

  assert.equal(transactionSteps.length, 1);
  assert.equal(transactionSteps[0]?.env?.INPUT_TOKEN, '${{ inputs.token }}');
  assert.equal(transactionSteps[0]?.env?.TARGET_SHA, '${{ github.sha }}');

  const transaction = readFileSync(path.join(root, 'release-tags', 'ReleaseTags.psm1'), 'utf8');

  assert.match(transaction, /INPUT_TOKEN\s*=\s*\$null/u);
  assert.match(transaction, /push.+--atomic.+--no-force/su);
  assert.doesNotMatch(transaction, /git tag/u);
});

void test('CI exercises one container tag and multiline build inputs through the consumer action', () => {
  const workflow = readYaml<WorkflowMetadata>(path.join(root, '.github', 'workflows', 'ci.yaml'));
  const steps = workflow.jobs?.['action-level']?.steps ?? [];
  const fixtures = steps.filter((step) => step.uses === '$/container-build-push');

  assert.equal(fixtures.length, 1);
  assert.equal(
    fixtures[0]?.with?.['build-contexts'],
    'fixture=tests/fixtures/go-chart\nsecondary=tests/fixtures/go-chart\n',
  );
  assert.equal(fixtures[0]?.with?.['build-args'], 'VERSION=fixture-version\nCOMMIT=fixture-commit\n');
  assert.equal(fixtures[0]?.with?.['cache-from'], 'type=gha,scope=github-actions-container-fixture\n');
  assert.equal(fixtures[0]?.with?.['cache-to'], 'type=gha,mode=max,scope=github-actions-container-fixture\n');
  assert.equal(fixtures[0]?.with?.version, 'ci');
  assert.equal('tags' in (fixtures[0]?.with ?? {}), false);
});
