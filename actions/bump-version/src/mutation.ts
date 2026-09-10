import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import {
  readCanonicalVersion,
  requireRegularContainedFile,
  resolveProject,
} from '../../../check-version/check-version.ts';
import { chartScalar, patchChartScalars, readChart } from './chart.ts';
import type { MutateVersionsOptions, MutationResult } from './contracts.ts';
import { incrementVersion } from './semantic-version.ts';

function fail(message: string): never {
  throw new Error(message);
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
    chartScalar(document, chartFile, 'appVersion');

    if (actualChartVersion !== chartVersion) {
      fail(`${chartFile} field version does not match ${chartVersionFile}`);
    }
  }

  const newApplicationVersion = options.go ? incrementVersion(applicationVersion, options.increment) : '';
  const newChartVersion = options.helm ? incrementVersion(chartVersion, options.increment) : '';

  if (options.go) {
    writeFileSync(applicationFile, `${newApplicationVersion}\n`, 'utf8');
  }

  if (options.helm) {
    writeFileSync(chartVersionFile, `${newChartVersion}\n`, 'utf8');
    patchChartScalars(
      chartFile,
      project,
      new Map([
        ['version', newChartVersion],
        ['appVersion', options.go ? newApplicationVersion : applicationVersion],
      ]),
    );
  }

  return { applicationVersion: newApplicationVersion, chartVersion: newChartVersion };
}
