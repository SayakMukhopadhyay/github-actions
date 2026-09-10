import * as core from '@actions/core';
import { pathToFileURL } from 'node:url';
import { readHelmDeploymentState } from './deployment-state.ts';

export * from './contracts.ts';
export * from './deployment-state.ts';
export * from './validation.ts';

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
