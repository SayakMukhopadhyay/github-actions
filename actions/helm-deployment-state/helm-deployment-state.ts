import * as core from '@actions/core';
import { existsSync, lstatSync, readFileSync, realpathSync } from 'node:fs';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isMap, isScalar, isSeq, parseDocument } from 'yaml';

const CANONICAL_VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const DEVELOPMENT_VERSION = /^0\.0\.0-build-([0-9a-f]{40})$/u;

export interface ReadHelmDeploymentStateOptions {
  checkoutPath: string;
  environment: string;
  chartName: string;
  dependency: string;
  wrapperChartPath: string;
}

export interface HelmDeploymentState {
  dependencyVersion: string;
  imageTag: string;
  chartSourceRef: string;
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

function requiredInput(value: string, label: string): string {
  if (value.trim().length === 0 || value.includes('\0') || value.includes('\n') || value.includes('\r')) {
    fail(`${label} must be a non-empty single-line value`);
  }
  return value;
}

function readAuthorityFile(file: string): string {
  if (!existsSync(file)) {
    fail(`authority file does not exist: ${file}`);
  }
  const status = lstatSync(file);
  if (status.isSymbolicLink()) {
    fail(`authority file must not be a symbolic link: ${file}`);
  }
  if (!status.isFile()) {
    fail(`authority path must be a regular file: ${file}`);
  }
  return readFileSync(file, 'utf8');
}

function parseMapping(file: string): ReturnType<typeof parseDocument> {
  const document = parseDocument(readAuthorityFile(file), { uniqueKeys: true });
  if (document.errors.length > 0 || !isMap(document.contents)) {
    fail(`${file} must contain a valid YAML mapping`);
  }
  return document;
}

function scalarValue(node: unknown, label: string): string {
  if (!isScalar(node)) {
    fail(`${label} must be a non-empty single-line scalar`);
  }
  const rawValue = node.value;
  if (
    typeof rawValue !== 'string' &&
    typeof rawValue !== 'number' &&
    typeof rawValue !== 'boolean' &&
    typeof rawValue !== 'bigint'
  ) {
    fail(`${label} must be a non-empty single-line scalar`);
  }
  const value = String(rawValue);
  if (value.trim().length === 0 || value.includes('\0') || value.includes('\n') || value.includes('\r')) {
    fail(`${label} must be a non-empty single-line scalar`);
  }
  return value;
}

function optionalStringScalar(node: unknown, label: string): string | undefined {
  if (node === undefined || node === null) {
    return undefined;
  }
  if (!isScalar(node) || typeof node.value !== 'string') {
    fail(`${label} must be a non-empty single-line string scalar`);
  }
  return scalarValue(node, label);
}

function sourceRef(version: string): string {
  const development = DEVELOPMENT_VERSION.exec(version);
  if (development !== null) {
    return development[1] ?? fail('development chart version did not contain a commit SHA');
  }
  if (CANONICAL_VERSION.test(version)) {
    return `chart-v${version}`;
  }
  return fail(`dependency version '${version}' is not a supported development or stable chart version`);
}

export function readHelmDeploymentState(options: ReadHelmDeploymentStateOptions): HelmDeploymentState {
  const chartName = requiredInput(options.chartName, 'chart-name');
  const environment = requiredInput(options.environment, 'environment');
  const requestedDependency = requiredInput(options.dependency || chartName, 'dependency');
  const requestedWrapper = options.wrapperChartPath || join(chartName, 'envs', environment);

  const checkout = realpathSync(options.checkoutPath);
  const lexicalWrapper = resolve(checkout, requestedWrapper);
  ensureContained(checkout, lexicalWrapper, 'wrapper-chart-path');
  if (!existsSync(lexicalWrapper)) {
    fail(`wrapper chart path does not exist: ${lexicalWrapper}`);
  }
  const wrapper = realpathSync(lexicalWrapper);
  ensureContained(checkout, wrapper, 'wrapper-chart-path');

  const chartFile = join(wrapper, 'Chart.yaml');
  const valuesFile = join(wrapper, 'values.yaml');
  const chart = parseMapping(chartFile);
  const values = parseMapping(valuesFile);

  const dependencies: unknown = chart.get('dependencies', true);
  if (!isSeq(dependencies)) {
    fail(`${chartFile} field dependencies must be a sequence`);
  }

  const matches: { versionNode: unknown; valuesRoot: string }[] = [];
  for (const dependency of dependencies.items) {
    if (!isMap(dependency)) {
      fail(`${chartFile} dependencies must be mappings`);
    }
    const name = optionalStringScalar(dependency.get('name', true), `${chartFile} dependency name`);
    if (name === undefined) {
      fail(`${chartFile} dependencies must have a name`);
    }
    const alias = optionalStringScalar(dependency.get('alias', true), `${chartFile} dependency alias`);
    if (requestedDependency === name || requestedDependency === alias) {
      matches.push({
        versionNode: dependency.get('version', true),
        valuesRoot: alias ?? name,
      });
    }
  }

  if (matches.length !== 1) {
    fail(
      `${chartFile} must contain exactly one dependency matching '${requestedDependency}'; found ${String(matches.length)}`,
    );
  }

  const match = matches[0] ?? fail('selected dependency was unavailable');
  const dependencyVersion = scalarValue(match.versionNode, `${chartFile} dependency version`);
  const rootNode: unknown = values.get(match.valuesRoot, true);
  if (!isMap(rootNode)) {
    fail(`${valuesFile} field ${match.valuesRoot} must be a mapping`);
  }
  const imageNode: unknown = rootNode.get('image', true);
  if (!isMap(imageNode)) {
    fail(`${valuesFile} field ${match.valuesRoot}.image must be a mapping`);
  }
  const imageTag = scalarValue(imageNode.get('tag', true), `${valuesFile} field ${match.valuesRoot}.image.tag`);

  return {
    dependencyVersion,
    imageTag,
    chartSourceRef: sourceRef(dependencyVersion),
  };
}

export function run(): void {
  try {
    const state = readHelmDeploymentState({
      checkoutPath: core.getInput('checkout-path'),
      environment: core.getInput('environment'),
      chartName: core.getInput('chart-name'),
      dependency: core.getInput('dependency'),
      wrapperChartPath: core.getInput('wrapper-chart-path'),
    });
    core.setOutput('dependency-version', state.dependencyVersion);
    core.setOutput('image-tag', state.imageTag);
    core.setOutput('chart-source-ref', state.chartSourceRef);
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : 'Unknown error occurred');
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run();
}
