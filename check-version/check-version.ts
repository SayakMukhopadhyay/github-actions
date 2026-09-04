import * as core from '@actions/core';
import { lstatSync, readFileSync, realpathSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseDocument } from 'yaml';

const CANONICAL_VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;

export interface CheckVersionOptions {
  workspace: string;
  workingDirectory: string;
  helm: boolean;
}

function fail(message: string): never {
  throw new Error(message);
}

function isContained(root: string, candidate: string): boolean {
  const relativeCandidate = relative(root, candidate);
  return (
    relativeCandidate !== '..' &&
    !relativeCandidate.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) &&
    !isAbsolute(relativeCandidate)
  );
}

export function requireRegularContainedFile(
  authorityRoot: string,
  file: string,
  label: string,
): string {
  const root = realpathSync(authorityRoot);
  let metadata;
  try {
    metadata = lstatSync(file);
  } catch {
    fail(`${label} file does not exist: ${file}`);
  }

  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    fail(`${label} must be a regular non-symlink file: ${file}`);
  }

  const resolvedFile = realpathSync(file);
  if (!isContained(root, resolvedFile)) {
    fail(`${label} file escapes the checkout: ${file}`);
  }
  return resolvedFile;
}

export function resolveProject(
  workspaceInput: string,
  workingDirectory: string,
): {
  workspace: string;
  project: string;
} {
  const workspace = realpathSync(workspaceInput);
  const requestedProject = resolve(workspace, workingDirectory);

  let project;
  try {
    project = realpathSync(requestedProject);
  } catch {
    fail('working-directory does not exist');
  }
  if (!isContained(workspace, project)) {
    fail('working-directory escapes the checkout');
  }

  return { workspace, project };
}

export function readCanonicalVersion(
  file: string,
  label: string,
  authorityRoot = dirname(file),
): string {
  const authorityFile = requireRegularContainedFile(authorityRoot, file, label);
  const contents = readFileSync(authorityFile, 'utf8');
  const match = /^([^\r\n]*)(?:\n)?$/.exec(contents);
  if (match === null || contents.endsWith('\n\n')) {
    fail(`${label} file must contain exactly one line: ${file}`);
  }

  const version = match[1];
  if (!CANONICAL_VERSION.test(version)) {
    fail(`${label} in ${file} must be canonical MAJOR.MINOR.PATCH; got '${version}'`);
  }

  return version;
}

export function readYamlScalar(file: string, field: string, authorityRoot = dirname(file)): string {
  const authorityFile = requireRegularContainedFile(authorityRoot, file, 'chart metadata');
  const document = parseDocument(readFileSync(authorityFile, 'utf8'), { uniqueKeys: true });
  if (document.errors.length > 0) {
    fail(`could not read ${file} field ${field}: ${document.errors[0].message}`);
  }

  const value = document.get(field);
  if (typeof value !== 'string' && typeof value !== 'number') {
    fail(`could not read ${file} field ${field}`);
  }

  return String(value);
}

export function checkVersion(options: CheckVersionOptions): void {
  const { project } = resolveProject(options.workspace, options.workingDirectory);
  const applicationFile = resolve(project, 'VERSION');
  const applicationVersion = readCanonicalVersion(applicationFile, 'application version', project);

  if (options.helm) {
    const chartVersionFile = resolve(project, 'charts', 'VERSION');
    const chartFile = resolve(project, 'charts', 'Chart.yaml');
    const chartVersion = readCanonicalVersion(chartVersionFile, 'chart version', project);
    const actualChartVersion = readYamlScalar(chartFile, 'version', project);
    const actualApplicationVersion = readYamlScalar(chartFile, 'appVersion', project);

    if (actualChartVersion !== chartVersion) {
      fail(
        `${chartFile} field version mismatch: expected '${chartVersion}', got '${actualChartVersion}'`,
      );
    }
    if (actualApplicationVersion !== applicationVersion) {
      fail(
        `${chartFile} field appVersion mismatch: expected '${applicationVersion}', got '${actualApplicationVersion}'`,
      );
    }
  }
}

export function run(): void {
  try {
    checkVersion({
      workspace: process.env.GITHUB_WORKSPACE ?? process.cwd(),
      workingDirectory: core.getInput('working-directory') || '.',
      helm: core.getInput('helm') === 'true',
    });
    core.info('Version metadata is consistent');
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : 'Unknown error occurred');
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run();
}
