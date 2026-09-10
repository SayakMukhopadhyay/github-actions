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

void test('rejects escaping paths, unsupported versions, duplicate dependencies, and malformed values', () => {
  const repository = temporaryDirectory();
  const wrapperPath = path.join('service', 'envs', 'production');
  const authority = writeWrapper(
    repository,
    wrapperPath,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 1.2.3-rc.1\n',
    'service:\n  image:\n    tag: candidate\n',
  );

  assert.throws(
    () => readHelmDeploymentState(options(repository, { wrapperChartPath: path.join('..', 'outside') })),
    /escapes the checkout/u,
  );

  assert.throws(() => readHelmDeploymentState(options(repository)), /not a supported development or stable/u);

  writeFileSync(
    authority.chartFile,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 1.2.3\n  - name: upstream\n    alias: service\n    version: 1.2.3\n',
  );
  assert.throws(() => readHelmDeploymentState(options(repository)), /exactly one dependency.*found 2/u);

  writeFileSync(
    authority.chartFile,
    `apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 0.0.0-build-${'A'.repeat(40)}\n`,
  );
  assert.throws(() => readHelmDeploymentState(options(repository)), /not a supported development or stable/u);

  writeFileSync(
    authority.chartFile,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 1.2.3\n',
  );
  writeFileSync(authority.valuesFile, 'service:\n  image: invalid\n');
  assert.throws(() => readHelmDeploymentState(options(repository)), /service\.image must be a mapping/u);

  writeFileSync(authority.valuesFile, 'service:\n  image:\n    tag: valid\nservice:\n  image:\n    tag: duplicate\n');
  assert.throws(() => readHelmDeploymentState(options(repository)), /valid YAML mapping/u);
});

void test('rejects non-canonical versions and empty scalar values', () => {
  const repository = temporaryDirectory();
  const wrapperPath = path.join('service', 'envs', 'production');
  const authority = writeWrapper(
    repository,
    wrapperPath,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 01.2.3\n',
    'service:\n  image:\n    tag: valid\n',
  );

  assert.throws(() => readHelmDeploymentState(options(repository)), /not a supported development or stable/u);

  writeFileSync(
    authority.chartFile,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 1.2.3+metadata\n',
  );
  assert.throws(() => readHelmDeploymentState(options(repository)), /not a supported development or stable/u);

  writeFileSync(
    authority.chartFile,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 1.2.3\n',
  );
  writeFileSync(authority.valuesFile, 'service:\n  image:\n    tag: "   "\n');
  assert.throws(() => readHelmDeploymentState(options(repository)), /image\.tag must be a non-empty/u);
  assert.throws(
    () => readHelmDeploymentState(options(repository, { dependency: '   ' })),
    /dependency must be a non-empty/u,
  );
});

void test('rejects malformed dependency and image mappings', () => {
  const repository = temporaryDirectory();
  const wrapperPath = path.join('service', 'envs', 'production');
  const authority = writeWrapper(
    repository,
    wrapperPath,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies: invalid\n',
    'service:\n  image:\n    tag: valid\n',
  );

  assert.throws(() => readHelmDeploymentState(options(repository)), /dependencies must be a sequence/u);

  writeFileSync(authority.chartFile, 'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - service\n');
  assert.throws(() => readHelmDeploymentState(options(repository)), /dependencies must be mappings/u);

  writeFileSync(
    authority.chartFile,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n',
  );
  assert.throws(() => readHelmDeploymentState(options(repository)), /dependency version must be a non-empty/u);

  writeFileSync(
    authority.chartFile,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 1.2.3\n',
  );
  writeFileSync(authority.valuesFile, 'service:\n  image:\n    tag:\n      nested: invalid\n');
  assert.throws(() => readHelmDeploymentState(options(repository)), /image\.tag must be a non-empty/u);
});

void test('rejects missing dependencies and symlinked authority files', (testContext) => {
  const repository = temporaryDirectory();
  const wrapperPath = path.join('service', 'envs', 'production');
  const authority = writeWrapper(
    repository,
    wrapperPath,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: other\n    version: 1.2.3\n',
    'other:\n  image:\n    tag: v1.2.3\n',
  );

  assert.throws(() => readHelmDeploymentState(options(repository)), /exactly one dependency.*found 0/u);

  const externalChart = path.join(repository, 'external-Chart.yaml');
  writeFileSync(
    externalChart,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 1.2.3\n',
  );
  rmSync(authority.chartFile);
  if (!createFileSymlinkOrSkip(testContext, externalChart, authority.chartFile)) {
    return;
  }

  assert.throws(() => readHelmDeploymentState(options(repository)), /must not be a symbolic link/u);

  rmSync(authority.chartFile);
  writeFileSync(
    authority.chartFile,
    'apiVersion: v2\nname: wrapper\nversion: 1.0.0\ndependencies:\n  - name: service\n    version: 1.2.3\n',
  );
  const externalValues = path.join(repository, 'external-values.yaml');
  writeFileSync(externalValues, 'service:\n  image:\n    tag: v1.2.3\n');
  rmSync(authority.valuesFile);
  if (!createFileSymlinkOrSkip(testContext, externalValues, authority.valuesFile)) {
    return;
  }

  assert.throws(() => readHelmDeploymentState(options(repository)), /must not be a symbolic link/u);
});
