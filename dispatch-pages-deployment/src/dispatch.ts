import {
  EVENT_TYPE,
  type DispatchDependencies,
  type DispatchInputs,
  type DispatchPayload,
  type GitHubContext,
  type Sleep,
} from './contracts.ts';
import { validateArtifactName, validateContext, validateRepository } from './validation.ts';

const MAX_ATTEMPTS = 3;
const REQUEST_TIMEOUT_MILLISECONDS = 15_000;
const MAX_RETRY_DELAY_MILLISECONDS = 30_000;

function fail(message: string): never {
  throw new Error(message);
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
    [408, 429, 500, 502, 503, 504].includes(response.status) ||
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

async function discardResponseBody(response: Response): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    /* Never expose response bodies. */
  }
}

const defaultSleep: Sleep = async (milliseconds) => {
  await new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
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

    const id = response.headers.get('x-github-request-id');
    const diagnostic = `status=${response.status}${id === null || id === '' ? '' : ` request-id=${id}`}`;

    if (!isRetryableResponse(response) || attempt === MAX_ATTEMPTS) {
      await discardResponseBody(response);
      fail(`repository dispatch failed: ${diagnostic}`);
    }

    const delay = retryDelay(response, attempt);

    await discardResponseBody(response);
    await sleep(delay);
  }
}
