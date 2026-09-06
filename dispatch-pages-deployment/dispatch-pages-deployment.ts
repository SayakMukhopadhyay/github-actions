import * as core from '@actions/core';
import { pathToFileURL } from 'node:url';

const EVENT_TYPE = 'deploy-pages';
const MAX_ATTEMPTS = 3;
const MAX_REPOSITORY_LENGTH = 256;
const MAX_ARTIFACT_NAME_LENGTH = 255;
const REQUEST_TIMEOUT_MILLISECONDS = 15_000;
const MAX_RETRY_DELAY_MILLISECONDS = 30_000;

export interface DispatchInputs {
  token: string;
  targetRepository: string;
  artifactName: string;
}

export interface GitHubContext {
  apiUrl: string;
  sourceRepository: string;
  sourceRunId: string;
  sourceSha: string;
}

export interface DispatchPayload {
  event_type: typeof EVENT_TYPE;
  client_payload: {
    source_repository: string;
    source_run_id: string;
    source_sha: string;
    artifact_name: string;
  };
}

export type Request = (url: string, init: RequestInit) => Promise<Response>;
export type Sleep = (milliseconds: number) => Promise<void>;

export interface DispatchDependencies {
  request?: Request;
  sleep?: Sleep;
}

function fail(message: string): never {
  throw new Error(message);
}

export function validateRepository(repository: string, label: string): string {
  if (
    repository.length === 0 ||
    repository.length > MAX_REPOSITORY_LENGTH ||
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u.test(repository)
  ) {
    fail(`${label} must use owner/repository form with only letters, numbers, dots, underscores, and hyphens`);
  }

  const [owner, name] = repository.split('/');
  if (owner === '.' || owner === '..' || name === '.' || name === '..') {
    fail(`${label} contains an invalid owner or repository name`);
  }
  return repository;
}

export function validateArtifactName(artifactName: string): string {
  if (artifactName.length === 0 || artifactName.length > MAX_ARTIFACT_NAME_LENGTH) {
    fail(`artifact-name must contain between 1 and ${MAX_ARTIFACT_NAME_LENGTH} characters`);
  }
  const forbiddenCharacters = new Set(['"', '*', ':', '<', '>', '?', '\\', '/', '|']);
  for (const character of artifactName) {
    const codePoint = character.codePointAt(0);
    if (codePoint === undefined || codePoint <= 31 || codePoint === 127 || forbiddenCharacters.has(character)) {
      fail('artifact-name contains a control character or a character rejected by GitHub artifacts');
    }
  }
  return artifactName;
}

function validateContext(context: GitHubContext): GitHubContext {
  validateRepository(context.sourceRepository, 'source repository');
  if (!/^[1-9][0-9]*$/u.test(context.sourceRunId)) {
    fail('source workflow run ID is unavailable or invalid');
  }
  if (!/^[0-9a-f]{40}$/iu.test(context.sourceSha)) {
    fail('source commit SHA is unavailable or invalid');
  }

  let apiUrl: URL;
  try {
    apiUrl = new URL(context.apiUrl);
  } catch {
    fail('GitHub API URL is invalid');
  }
  if (
    apiUrl.protocol !== 'https:' ||
    apiUrl.username !== '' ||
    apiUrl.password !== '' ||
    apiUrl.search !== '' ||
    apiUrl.hash !== ''
  ) {
    fail('GitHub API URL must be an HTTPS URL without credentials, a query, or a fragment');
  }

  return context;
}

export function createDispatchPayload(context: GitHubContext, artifactName: string): DispatchPayload {
  return {
    event_type: EVENT_TYPE,
    client_payload: {
      source_repository: context.sourceRepository,
      source_run_id: context.sourceRunId,
      source_sha: context.sourceSha,
      artifact_name: artifactName,
    },
  };
}

function isRetryableResponse(response: Response): boolean {
  return (
    response.status === 408 ||
    response.status === 429 ||
    response.status === 500 ||
    response.status === 502 ||
    response.status === 503 ||
    response.status === 504 ||
    (response.status === 403 && response.headers.has('retry-after'))
  );
}

function retryDelay(response: Response, attempt: number, now = Date.now()): number {
  const retryAfter = response.headers.get('retry-after');
  if (retryAfter !== null) {
    const seconds = Number(retryAfter);
    if (Number.isFinite(seconds) && seconds >= 0) {
      return Math.min(seconds * 1_000, MAX_RETRY_DELAY_MILLISECONDS);
    }
    const date = Date.parse(retryAfter);
    if (Number.isFinite(date)) {
      return Math.min(Math.max(date - now, 0), MAX_RETRY_DELAY_MILLISECONDS);
    }
  }
  return 1_000 * 2 ** (attempt - 1);
}

function requestId(response: Response): string {
  const value = response.headers.get('x-github-request-id');
  return value === null || value === '' ? '' : ` request-id=${value}`;
}

async function discardResponseBody(response: Response): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // Response bodies are intentionally excluded from diagnostics, including cancellation failures.
  }
}

const defaultSleep: Sleep = async (milliseconds) => {
  await new Promise<void>((resolve) => {
    setTimeout(resolve, milliseconds);
  });
};

export async function dispatchPagesDeployment(
  inputs: DispatchInputs,
  context: GitHubContext,
  dependencies: DispatchDependencies = {},
): Promise<void> {
  if (inputs.token.trim() === '') {
    fail('github-token is required');
  }
  const targetRepository = validateRepository(inputs.targetRepository, 'target-repository');
  const artifactName = validateArtifactName(inputs.artifactName);
  validateContext(context);

  const request = dependencies.request ?? fetch;
  const sleep = dependencies.sleep ?? defaultSleep;
  const endpoint = `${context.apiUrl.replace(/\/+$/u, '')}/repos/${targetRepository}/dispatches`;
  const body = JSON.stringify(createDispatchPayload(context, artifactName));

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    let response: Response;
    try {
      response = await request(endpoint, {
        method: 'POST',
        headers: {
          accept: 'application/vnd.github+json',
          authorization: `Bearer ${inputs.token}`,
          'content-type': 'application/json',
          'user-agent': 'SayakMukhopadhyay-github-actions-dispatch-pages-deployment',
          'x-github-api-version': '2022-11-28',
        },
        body,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MILLISECONDS),
      });
    } catch {
      if (attempt === MAX_ATTEMPTS) {
        fail(`repository dispatch failed before receiving a response after ${MAX_ATTEMPTS} attempts`);
      }
      await sleep(1_000 * 2 ** (attempt - 1));
      continue;
    }

    if (response.ok) {
      await discardResponseBody(response);
      return;
    }

    const diagnostic = `status=${response.status}${requestId(response)}`;
    if (!isRetryableResponse(response) || attempt === MAX_ATTEMPTS) {
      await discardResponseBody(response);
      fail(`repository dispatch failed: ${diagnostic}`);
    }

    const delay = retryDelay(response, attempt);
    await discardResponseBody(response);
    await sleep(delay);
  }
}

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
      {
        token,
        targetRepository,
        artifactName: core.getInput('artifact-name', { required: true }),
      },
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
