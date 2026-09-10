/* eslint-disable @typescript-eslint/no-unused-vars */
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, test, type TestContext } from 'node:test';
import { parse } from 'yaml';
import { readHelmDeploymentState } from '../actions/helm-deployment-state/src/deployment-state.ts';

interface ActionStep {
  id?: unknown;
  run?: unknown;
  uses?: unknown;
  with?: Record<string, unknown>;
}

interface ActionMetadata {
  inputs?: Record<string, { default?: unknown; required?: unknown }>;
  outputs?: Record<string, { value?: unknown }>;
  runs?: { steps?: ActionStep[]; using?: unknown };
}

const root = path.resolve(import.meta.dirname, '..');
const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

function temporaryDirectory(): string {
  const directory = mkdtempSync(path.join(tmpdir(), 'helm-deployment-state-'));
  temporaryDirectories.push(directory);
  return directory;
}

function writeWrapper(
  repository: string,
  wrapperPath: string,
  chart: string,
  values: string,
): { chartFile: string; valuesFile: string } {
  const wrapper = path.join(repository, wrapperPath);
  mkdirSync(wrapper, { recursive: true });

  const chartFile = path.join(wrapper, 'Chart.yaml');
  const valuesFile = path.join(wrapper, 'values.yaml');

  writeFileSync(chartFile, chart);
  writeFileSync(valuesFile, values);

  return { chartFile, valuesFile };
}

function options(repository: string, overrides: Partial<Parameters<typeof readHelmDeploymentState>[0]> = {}) {
  return {
    checkoutPath: repository,
    environment: 'production',
    chartName: 'service',
    dependency: '',
    wrapperChartPath: '',
    ...overrides,
  };
}

function createFileSymlinkOrSkip(testContext: TestContext, target: string, link: string): boolean {
  try {
    symlinkSync(target, link, 'file');

    return true;
  } catch (error) {
    const code = error instanceof Error && 'code' in error ? error.code : undefined;

    if (code === 'EPERM' || code === 'EACCES' || code === 'ENOTSUP') {
      testContext.skip(`file symlinks are unavailable on this platform (${String(code)})`);

      return false;
    }

    throw error;
  }
}

void test('reads a stable dependency from the default wrapper path', () => {
  const repository = temporaryDirectory();
  writeWrapper(
    repository,
    path.join('service', 'envs', 'production'),
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 2.3.4\n',
    'service:\n  image:\n    tag: v2.3.4\n',
  );

  assert.deepEqual(readHelmDeploymentState(options(repository)), {
    dependencyVersion: '2.3.4',
    imageTag: 'v2.3.4',
    chartSourceRef: 'chart-v2.3.4',
  });
});

void test('reads a development dependency by either name or alias and uses the alias values root', () => {
  const repository = temporaryDirectory();
  const sha = '0123456789abcdef0123456789abcdef01234567';
  writeWrapper(
    repository,
    path.join('service', 'envs', 'production'),
    `apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: upstream\n    alias: service\n    version: 0.0.0-build-${sha}\n`,
    'service:\n  image:\n    tag: build-0123456789abcdef\n',
  );

  const expected = {
    dependencyVersion: `0.0.0-build-${sha}`,
    imageTag: 'build-0123456789abcdef',
    chartSourceRef: sha,
  };

  assert.deepEqual(readHelmDeploymentState(options(repository)), expected);
  assert.deepEqual(readHelmDeploymentState(options(repository, { dependency: 'upstream' })), expected);
});

void test('honors an explicit contained wrapper chart override', () => {
  const repository = temporaryDirectory();
  writeWrapper(
    repository,
    path.join('custom', 'wrapper'),
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: selected\n    version: 7.8.9\n',
    'selected:\n  image:\n    tag: release-7.8.9\n',
  );

  assert.deepEqual(
    readHelmDeploymentState(
      options(repository, { dependency: 'selected', wrapperChartPath: path.join('custom', 'wrapper') }),
    ),
    {
      dependencyVersion: '7.8.9',
      imageTag: 'release-7.8.9',
      chartSourceRef: 'chart-v7.8.9',
    },
  );
});

void test('public metadata keeps the read-only checkout and output contract narrow', () => {
  const metadata = parse(
    readFileSync(path.join(root, 'helm-deployment-state', 'action.yaml'), 'utf8'),
  ) as ActionMetadata;

  assert.deepEqual(Object.keys(metadata.inputs ?? {}).sort(), [
    'chart-name',
    'dependency',
    'environment',
    'target-ref',
    'target-repository',
    'token',
    'wrapper-chart-path',
  ]);
  for (const required of ['token', 'environment', 'chart-name']) {
    assert.equal(metadata.inputs?.[required]?.required, true, required);
  }

  assert.equal(metadata.inputs?.dependency?.default, '');
  assert.equal(metadata.inputs?.['target-repository']?.default, 'SayakMukhopadhyay/k8s-landscape-charts');
  assert.equal(metadata.inputs?.['target-ref']?.default, 'main');
  assert.equal(metadata.inputs?.['wrapper-chart-path']?.default, '');

  assert.deepEqual(Object.keys(metadata.outputs ?? {}).sort(), ['chart-source-ref', 'dependency-version', 'image-tag']);
  assert.equal(metadata.outputs?.['dependency-version']?.value, '${{ steps.state.outputs.dependency-version }}');
  assert.equal(metadata.outputs?.['image-tag']?.value, '${{ steps.state.outputs.image-tag }}');
  assert.equal(metadata.outputs?.['chart-source-ref']?.value, '${{ steps.state.outputs.chart-source-ref }}');

  assert.equal(metadata.runs?.using, 'composite');

  const steps = metadata.runs?.steps ?? [];

  assert.equal(steps.length, 2);
  assert.match(String(steps[0]?.uses), /^actions\/checkout@[0-9a-f]{40}$/u);
  assert.equal(steps[0]?.with?.path, '.helm-deployment-state');
  assert.equal(steps[0]?.with?.['persist-credentials'], false);
  assert.equal(steps[0]?.with?.token, '${{ inputs.token }}');
  assert.equal(steps[1]?.uses, '$/actions/helm-deployment-state');
  assert.equal(steps[1]?.id, 'state');
  assert.equal(
    steps.some((step) => step.run !== undefined),
    false,
  );
  assert.equal(
    steps.some((step) => /is-file-changed|setup-helm/iu.test(String(step.uses))),
    false,
  );
});
