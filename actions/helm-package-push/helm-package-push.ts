import * as core from '@actions/core';
import { existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isMap, isScalar, isSeq, parseDocument } from 'yaml';

const CANONICAL_VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const FULL_COMMIT_SHA = /^[0-9a-f]{40}$/i;

export interface PrepareHelmPackageOptions {
  workspace: string;
  workingDirectory: string;
  development: boolean;
  commitSha: string;
  runnerTemp: string;
}

export interface HelmPackagePreparation {
  chartDirectory: string;
  chartName: string;
  chartVersion: string;
  repositoriesFile: string;
}

function fail(message: string): never {
  throw new Error(message);
}

function ensureContained(parent: string, child: string, label: string): void {
  const relativeChild = relative(parent, child);
  if (
    relativeChild === '..' ||
    relativeChild.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) ||
    isAbsolute(relativeChild)
  ) {
    fail(`${label} escapes the checkout`);
  }
}

function readCanonicalVersion(file: string): string {
  if (!existsSync(file)) {
    fail(`chart version file does not exist: ${file}`);
  }

  const contents = readFileSync(file, 'utf8');
  const match = /^([^\r\n]*)(?:\n)?$/.exec(contents);
  if (match === null || contents.endsWith('\n\n')) {
    fail(`chart version file must contain exactly one line: ${file}`);
  }

  const version = match[1];
  if (!CANONICAL_VERSION.test(version)) {
    fail(`chart version must be canonical MAJOR.MINOR.PATCH; got '${version}'`);
  }
  return version;
}

function requiredScalar(mapping: ReturnType<typeof parseDocument>, file: string, field: string): string {
  const node: unknown = mapping.get(field, true);
  if (!isScalar(node) || (typeof node.value !== 'string' && typeof node.value !== 'number')) {
    fail(`could not read ${file} field ${field}`);
  }
  const value = String(node.value);
  if (value.length === 0 || value.includes('\0') || value.includes('\n') || value.includes('\r')) {
    fail(`${file} field ${field} must be a non-empty single-line scalar`);
  }
  return value;
}

function dependencyRepositories(document: ReturnType<typeof parseDocument>, file: string): Buffer {
  const dependencies: unknown = document.get('dependencies', true);
  if (dependencies === undefined || dependencies === null) {
    return Buffer.alloc(0);
  }
  if (!isSeq(dependencies)) {
    fail(`${file} field dependencies must be a sequence`);
  }

  const records: string[] = [];
  for (const dependency of dependencies.items) {
    if (!isMap(dependency)) {
      fail(`${file} dependencies must be mappings`);
    }
    const repositoryNode: unknown = dependency.get('repository', true);
    if (!isScalar(repositoryNode) || typeof repositoryNode.value !== 'string') {
      continue;
    }
    const repository = repositoryNode.value;
    if (!repository.startsWith('http://') && !repository.startsWith('https://')) {
      continue;
    }

    const nameNode: unknown = dependency.get('name', true);
    if (!isScalar(nameNode) || typeof nameNode.value !== 'string') {
      fail(`${file} HTTP dependencies must have a string name`);
    }
    const name = nameNode.value;
    if (
      name.length === 0 ||
      name.startsWith('-') ||
      name.includes('\0') ||
      name.includes('\n') ||
      name.includes('\r') ||
      repository.includes('\0') ||
      repository.includes('\n') ||
      repository.includes('\r')
    ) {
      fail(`${file} contains an unsafe HTTP dependency repository record`);
    }
    records.push(name, repository);
  }

  return records.length === 0 ? Buffer.alloc(0) : Buffer.from(`${records.join('\0')}\0`, 'utf8');
}

export function prepareHelmPackage(options: PrepareHelmPackageOptions): HelmPackagePreparation {
  const workspace = realpathSync(options.workspace);
  const requestedChart = resolve(workspace, options.workingDirectory, 'charts');
  if (!existsSync(requestedChart)) {
    fail('chart directory does not exist');
  }
  const chartDirectory = realpathSync(requestedChart);
  ensureContained(workspace, chartDirectory, 'working-directory');

  const chartFile = join(chartDirectory, 'Chart.yaml');
  if (!existsSync(chartFile)) {
    fail(`could not read chart metadata: ${chartFile}`);
  }
  const document = parseDocument(readFileSync(chartFile, 'utf8'), { uniqueKeys: true });
  if (document.errors.length > 0 || !isMap(document.contents)) {
    fail(`${chartFile} must contain a valid YAML mapping`);
  }

  const chartName = requiredScalar(document, chartFile, 'name');
  if (chartName.startsWith('-') || chartName.includes('/') || chartName.includes('\\')) {
    fail(`${chartFile} field name cannot be used as a package filename`);
  }
  const baseVersion = readCanonicalVersion(join(chartDirectory, 'VERSION'));
  const declaredVersion = requiredScalar(document, chartFile, 'version');
  if (declaredVersion !== baseVersion) {
    fail(`Chart.yaml field version mismatch: expected '${baseVersion}', got '${declaredVersion}'`);
  }

  let chartVersion = baseVersion;
  if (options.development) {
    if (!FULL_COMMIT_SHA.test(options.commitSha)) {
      fail('github.sha must be a full 40-character commit SHA for development packages');
    }
    chartVersion = `${baseVersion}-${options.commitSha.toLowerCase()}`;
  }

  const runnerTemp = realpathSync(options.runnerTemp);
  const preparationDirectory = mkdtempSync(join(runnerTemp, 'helm-package-push-'));
  const repositoriesFile = join(preparationDirectory, 'repositories');
  writeFileSync(repositoriesFile, dependencyRepositories(document, chartFile));

  return { chartDirectory, chartName, chartVersion, repositoriesFile };
}

export function run(): void {
  try {
    const result = prepareHelmPackage({
      workspace: process.env.GITHUB_WORKSPACE ?? process.cwd(),
      workingDirectory: core.getInput('working-directory') || '.',
      development: core.getInput('development') === 'true',
      commitSha: core.getInput('commit-sha'),
      runnerTemp: process.env.RUNNER_TEMP ?? process.cwd(),
    });
    core.setOutput('chart-directory', result.chartDirectory);
    core.setOutput('chart-name', result.chartName);
    core.setOutput('chart-version', result.chartVersion);
    core.setOutput('repositories-file', result.repositoriesFile);
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : 'Unknown error occurred');
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run();
}
