import * as core from '@actions/core';
import { pathToFileURL } from 'node:url';
import { mutateVersions } from './mutation.ts';

export * from './chart.ts';
export * from './contracts.ts';
export * from './mutation.ts';
export * from './semantic-version.ts';

export function run(): void {
  try {
    const helm = core.getInput('helm') === 'true';
    const go = core.getInput('go') === 'true';

    const result = mutateVersions({
      workspace: process.env.GITHUB_WORKSPACE ?? process.cwd(),
      workingDirectory: core.getInput('working-directory') || '.',
      increment: core.getInput('increment', { required: true }),
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
