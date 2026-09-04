import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, test } from 'node:test';
import { prepareHelmPackage } from '../actions/helm-package-push/helm-package-push.ts';

const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

function temporaryDirectory(): string {
  const directory = mkdtempSync(join(tmpdir(), 'github-actions-helm-'));
  temporaryDirectories.push(directory);
  return directory;
}

function writeChart(
  repository: string,
  version = '0.4.0',
  extra = '',
): { chartDirectory: string; runnerTemp: string } {
  const chartDirectory = join(repository, 'charts');
  const runnerTemp = join(repository, 'runner-temp');
  mkdirSync(chartDirectory, { recursive: true });
  mkdirSync(runnerTemp);
  writeFileSync(join(chartDirectory, 'VERSION'), `${version}\n`);
  writeFileSync(
    join(chartDirectory, 'Chart.yaml'),
    `apiVersion: v2\nname: fixture\ntype: application\nversion: ${version}\n${extra}`,
  );
  return { chartDirectory, runnerTemp };
}

void test('helm-package-push prepares stable and development chart metadata', () => {
  const stableRepository = temporaryDirectory();
  const stable = writeChart(stableRepository);
  const stableResult = prepareHelmPackage({
    workspace: stableRepository,
    workingDirectory: '.',
    development: false,
    commitSha: 'not-needed-for-stable-builds',
    runnerTemp: stable.runnerTemp,
  });
  assert.equal(stableResult.chartDirectory, stable.chartDirectory);
  assert.equal(stableResult.chartName, 'fixture');
  assert.equal(stableResult.chartVersion, '0.4.0');
  assert.equal(readFileSync(stableResult.repositoriesFile).length, 0);

  const developmentRepository = temporaryDirectory();
  const development = writeChart(developmentRepository);
  const commitSha = 'ABCDEF1234567890ABCDEF1234567890ABCDEF12';
  const developmentResult = prepareHelmPackage({
    workspace: developmentRepository,
    workingDirectory: '.',
    development: true,
    commitSha,
    runnerTemp: development.runnerTemp,
  });
  assert.equal(developmentResult.chartVersion, `0.4.0-${commitSha.toLowerCase()}`);
});

void test('helm-package-push records only HTTP dependency repositories without executing commands', () => {
  const repository = temporaryDirectory();
  const fixture = writeChart(
    repository,
    '0.4.0',
    `dependencies:
  - name: remote
    version: 1.0.0
    repository: https://charts.example.test/stable
  - name: local
    version: 1.0.0
    repository: file://../local
`,
  );
  const result = prepareHelmPackage({
    workspace: repository,
    workingDirectory: '.',
    development: false,
    commitSha: '',
    runnerTemp: fixture.runnerTemp,
  });

  assert.deepEqual(readFileSync(result.repositoriesFile).toString('utf8').split('\0'), [
    'remote',
    'https://charts.example.test/stable',
    '',
  ]);
});

void test('helm-package-push rejects invalid authorities and paths', () => {
  const root = temporaryDirectory();
  const repository = join(root, 'repository');
  mkdirSync(repository);
  const fixture = writeChart(repository);

  writeFileSync(join(fixture.chartDirectory, 'VERSION'), '0.4.0\n0.5.0\n');
  assert.throws(
    () =>
      prepareHelmPackage({
        workspace: repository,
        workingDirectory: '.',
        development: false,
        commitSha: '',
        runnerTemp: fixture.runnerTemp,
      }),
    /exactly one line/,
  );

  writeFileSync(join(fixture.chartDirectory, 'VERSION'), '0.5.0\n');
  assert.throws(
    () =>
      prepareHelmPackage({
        workspace: repository,
        workingDirectory: '.',
        development: false,
        commitSha: '',
        runnerTemp: fixture.runnerTemp,
      }),
    /field version mismatch/,
  );

  assert.throws(
    () =>
      prepareHelmPackage({
        workspace: repository,
        workingDirectory: '..',
        development: false,
        commitSha: '',
        runnerTemp: fixture.runnerTemp,
      }),
    /escapes the checkout|chart directory does not exist/,
  );
});

void test('helm-package-push requires a full commit SHA only for development packages', () => {
  const repository = temporaryDirectory();
  const fixture = writeChart(repository);
  assert.throws(
    () =>
      prepareHelmPackage({
        workspace: repository,
        workingDirectory: '.',
        development: true,
        commitSha: 'abcdef',
        runnerTemp: fixture.runnerTemp,
      }),
    /full 40-character commit SHA/,
  );
});

void test('Helm delivery TypeScript never invokes external commands', () => {
  const source = readFileSync(
    join(import.meta.dirname, '..', 'actions', 'helm-package-push', 'helm-package-push.ts'),
    'utf8',
  );
  const commandExecutionApi = new RegExp(
    String.raw`(?:node:)?child_process|\bexecFile(?:Sync)?\b|\bexecSync\b|\bspawn(?:Sync)?\b|\bexeca\b`,
    'u',
  );
  assert.doesNotMatch(source, commandExecutionApi);
});

void test('container-build-push keeps preparation inline and omits an empty auth token', () => {
  const metadata = readFileSync(
    join(import.meta.dirname, '..', 'container-build-push', 'action.yaml'),
    'utf8',
  );
  assert.doesNotMatch(metadata, new RegExp(String.raw`prepare\.sh`, 'u'));
  assert.match(metadata, new RegExp(String.raw`secrets: \$\{\{ inputs\.auth-token != ''`, 'u'));
});
