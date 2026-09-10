import * as core from '@actions/core';
import { pathToFileURL } from 'node:url';
import { prepareHelmPackage } from './preparation.ts';

export * from './contracts.ts';
export * from './preparation.ts';

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
