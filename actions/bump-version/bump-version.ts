import * as core from '@actions/core';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isMap, isScalar, parseDocument } from 'yaml';
import {
  readCanonicalVersion,
  requireRegularContainedFile,
  resolveProject,
} from '../../check-version/check-version.ts';

export type Increment = 'patch' | 'minor' | 'major';

export interface MutateVersionsOptions {
  workspace: string;
  workingDirectory: string;
  increment: string;
  helm: boolean;
  go: boolean;
}

export interface MutationResult {
  applicationVersion: string;
  chartVersion: string;
}

function fail(message: string): never {
  throw new Error(message);
}

export function incrementVersion(version: string, increment: string): string {
  if (increment !== 'patch' && increment !== 'minor' && increment !== 'major') {
    fail('increment must be patch, minor, or major');
  }

  const [majorText, minorText, patchText] = version.split('.');
  const major = BigInt(majorText);
  const minor = BigInt(minorText);
  const patch = BigInt(patchText);
  if (increment === 'major') {
    return `${major + 1n}.0.0`;
  }
  if (increment === 'minor') {
    return `${major}.${minor + 1n}.0`;
  }
  return `${major}.${minor}.${patch + 1n}`;
}

function readChart(
  file: string,
  authorityRoot: string,
): { source: string; document: ReturnType<typeof parseDocument> } {
  const authorityFile = requireRegularContainedFile(authorityRoot, file, 'chart metadata');
  const source = readFileSync(authorityFile, 'utf8');
  const document = parseDocument(source, { keepSourceTokens: true, uniqueKeys: true });
  if (document.errors.length > 0 || !isMap(document.contents)) {
    fail(`${file} must contain a valid YAML mapping`);
  }
  return { source, document };
}

function chartScalar(document: ReturnType<typeof parseDocument>, file: string, field: string): string {
  const node: unknown = document.get(field, true);
  if (!isScalar(node) || (typeof node.value !== 'string' && typeof node.value !== 'number')) {
    fail(`${file} must contain exactly one top-level ${field} field`);
  }
  return String(node.value);
}

function patchChartScalars(file: string, authorityRoot: string, replacements: ReadonlyMap<string, string>): void {
  const authorityFile = requireRegularContainedFile(authorityRoot, file, 'chart metadata');
  const { source, document } = readChart(authorityFile, authorityRoot);
  const patches: { start: number; end: number; replacement: string }[] = [];

  for (const [field, value] of replacements) {
    const node: unknown = document.get(field, true);
    if (!isScalar(node) || node.range == null) {
      fail(`${file} must contain exactly one top-level ${field} field`);
    }
    const [start, end] = node.range;
    const original = source.slice(start, end);
    const quote =
      original.startsWith('"') && original.endsWith('"')
        ? '"'
        : original.startsWith("'") && original.endsWith("'")
          ? "'"
          : '';
    patches.push({ start, end, replacement: `${quote}${value}${quote}` });
  }

  let updated = source;
  for (const patch of patches.sort((left, right) => right.start - left.start)) {
    updated = `${updated.slice(0, patch.start)}${patch.replacement}${updated.slice(patch.end)}`;
  }

  const verified = parseDocument(updated, { uniqueKeys: true });
  if (verified.errors.length > 0) {
    fail(`could not update ${file}`);
  }
  for (const [field, value] of replacements) {
    if (chartScalar(verified, file, field) !== value) {
      fail(`could not update ${file} field ${field}`);
    }
  }
  writeFileSync(authorityFile, updated, 'utf8');
}

export function mutateVersions(options: MutateVersionsOptions): MutationResult {
  if (!options.helm && !options.go) {
    return { applicationVersion: '', chartVersion: '' };
  }

  const { project } = resolveProject(options.workspace, options.workingDirectory);
  const applicationFile = requireRegularContainedFile(project, resolve(project, 'VERSION'), 'application version');
  const applicationVersion = readCanonicalVersion(applicationFile, 'application version', project);
  let chartVersion = '';
  let chartFile = '';
  let chartVersionFile = '';

  if (options.helm) {
    chartVersionFile = requireRegularContainedFile(project, resolve(project, 'charts', 'VERSION'), 'chart version');
    chartFile = requireRegularContainedFile(project, resolve(project, 'charts', 'Chart.yaml'), 'chart metadata');
    chartVersion = readCanonicalVersion(chartVersionFile, 'chart version', project);
    const { document } = readChart(chartFile, project);
    const actualChartVersion = chartScalar(document, chartFile, 'version');
    const actualApplicationVersion = chartScalar(document, chartFile, 'appVersion');
    if (actualChartVersion !== chartVersion) {
      fail(`${chartFile} field version does not match ${chartVersionFile}`);
    }
    if (actualApplicationVersion !== applicationVersion) {
      fail(`${chartFile} field appVersion does not match ${applicationFile}`);
    }
  }

  const newApplicationVersion = options.go ? incrementVersion(applicationVersion, options.increment) : '';
  const newChartVersion = options.helm ? incrementVersion(chartVersion, options.increment) : '';

  if (options.go) {
    writeFileSync(applicationFile, `${newApplicationVersion}\n`, 'utf8');
  }
  if (options.helm) {
    writeFileSync(chartVersionFile, `${newChartVersion}\n`, 'utf8');
    const replacements = new Map<string, string>([['version', newChartVersion]]);
    if (options.go) {
      replacements.set('appVersion', newApplicationVersion);
    }
    patchChartScalars(chartFile, project, replacements);
  }

  return { applicationVersion: newApplicationVersion, chartVersion: newChartVersion };
}

export function run(): void {
  try {
    const helm = core.getInput('helm') === 'true';
    const go = core.getInput('go') === 'true';
    const result = mutateVersions({
      workspace: process.env.GITHUB_WORKSPACE ?? process.cwd(),
      workingDirectory: core.getInput('working-directory') || '.',
      increment: core.getInput('increment') || 'patch',
      helm,
      go,
    });

    if (!helm && !go) {
      core.info('No version target was selected; nothing to do');
    }
    core.setOutput('application-version', result.applicationVersion);
    core.setOutput('chart-version', result.chartVersion);
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : 'Unknown error occurred');
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run();
}
