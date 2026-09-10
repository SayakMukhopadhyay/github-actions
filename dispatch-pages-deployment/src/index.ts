import * as core from '@actions/core';
import { pathToFileURL } from 'node:url';
import { EVENT_TYPE, type GitHubContext } from './contracts.ts';
import { dispatchPagesDeployment } from './dispatch.ts';

export * from './contracts.ts';
export * from './dispatch.ts';
export * from './validation.ts';

function currentGitHubContext(): GitHubContext {
  return {
    apiUrl: process.env.GITHUB_API_URL ?? 'https://api.github.com',
    sourceRepository: process.env.GITHUB_REPOSITORY ?? '',
    sourceRunId: process.env.GITHUB_RUN_ID ?? '',
    sourceSha: process.env.GITHUB_SHA ?? '',
  };
}

export async function run(): Promise<void> {
  try {
    const token = core.getInput('github-token', { required: true });
    core.setSecret(token);

    const targetRepository = core.getInput('target-repository', { required: true });

    await dispatchPagesDeployment(
      { token, targetRepository, artifactName: core.getInput('artifact-name', { required: true }) },
      currentGitHubContext(),
    );

    core.info(`Dispatched ${EVENT_TYPE} to ${targetRepository}`);
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : 'Unknown error occurred');
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  void run();
}
