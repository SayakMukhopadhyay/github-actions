/* eslint-disable @typescript-eslint/no-unused-vars */
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import {
  generateNotes,
  renderReleaseBody,
  run,
  SafeActionFailure,
  validateGeneratedNotes,
  validateReleaseFacts,
  type DiagnosticEvent,
  type ReleaseFacts,
  type ResponseClient,
  type WorkloadIdentityClientOptions,
} from '../actions/create-release/src/index.ts';

const facts: ReleaseFacts = {
  schemaVersion: 1,
  repository: 'Owner/Project',
  serverUrl: 'https://github.example',
  tagName: 'charts/0.2.0',
  targetObject: 'a'.repeat(40),
  targetCommit: 'b'.repeat(40),
  previousTag: 'charts/0.1.0',
  previousObject: 'e'.repeat(40),
  commits: [
    { sha: 'c'.repeat(40), subject: 'Direct mainline change' },
    {
      sha: 'd'.repeat(40),
      subject: 'Treat [links](https://evil.example) and @mentions as text',
    },
  ],
  omittedCommitCount: 0,
};

function completedResponse(text: string, additionalOutput: unknown[] = []): unknown {
  return {
    status: 'completed',
    output: [
      ...additionalOutput,
      {
        type: 'message',
        role: 'assistant',
        status: 'completed',
        content: [{ type: 'output_text', text }],
      },
    ],
    output_text: text,
  };
}

const githubOidcClaims = {
  iss: 'https://token.actions.githubusercontent.com',
  aud: 'https://api.openai.com/v1',
  sub: 'repo:Owner/Project:environment:production',
  repository: 'Owner/Project',
  environment: 'production',
  job_workflow_ref: 'Owner/Project/.github/workflows/release.yaml@refs/heads/main',
  workflow_ref: 'Owner/Project/.github/workflows/release.yaml@refs/heads/main',
  ref: 'refs/heads/main',
  sha: 'a'.repeat(40),
};
const githubOidcToken = `eyJhbGciOiJSUzI1NiJ9.${Buffer.from(JSON.stringify(githubOidcClaims)).toString('base64url')}.signature-secret`;

const releaseInputNames = [
  'openai-wif-audience',
  'openai-identity-provider-id',
  'openai-service-account-id',
  'context-file',
  'facts-file',
  'body-file',
] as const;
type ReleaseInputName = (typeof releaseInputNames)[number];

interface RunOptions {
  bodyInput?: string;
  contextInput?: string;
  factsContent?: string;
  factsInput?: string;
  modelError?: Error;
  omitInput?: ReleaseInputName;
  precreateBody?: boolean;
  unsetRunnerTemp?: boolean;
}

interface RunResult {
  body: string | undefined;
  clientCreated: boolean;
  exitCode: number | string | null | undefined;
  observedOptions: WorkloadIdentityClientOptions | undefined;
  runnerTemp: string;
  stderr: string;
}

function inputEnvironmentName(name: ReleaseInputName): string {
  return `INPUT_${name.toUpperCase()}`;
}

async function exerciseRun(options: RunOptions = {}): Promise<RunResult> {
  const runnerTemp = await mkdtemp(join(tmpdir(), 'create-release-diagnostics-'));
  const sessionDirectory = join(runnerTemp, 'release-session');
  const contextPath = join(sessionDirectory, 'context.txt');
  const factsPath = join(sessionDirectory, 'facts.json');
  const bodyPath = join(sessionDirectory, 'body.md');
  const environmentNames = [...releaseInputNames.map(inputEnvironmentName), 'RUNNER_TEMP'];
  const previousEnvironment = new Map(environmentNames.map((name) => [name, process.env[name]]));
  const previousExitCode = process.exitCode;
  const originalStderrWrite = process.stderr.write.bind(process.stderr);

  let clientCreated = false;
  let observedOptions: WorkloadIdentityClientOptions | undefined;
  let stderr = '';

  try {
    await mkdir(sessionDirectory);
    await writeFile(contextPath, 'untrusted-context-secret-value', 'utf8');
    await writeFile(factsPath, options.factsContent ?? JSON.stringify(facts), 'utf8');
    if (options.precreateBody) {
      await writeFile(bodyPath, 'untrusted-existing-body-value', 'utf8');
    }

    for (const name of environmentNames) {
      delete process.env[name];
    }

    const inputValues: Record<ReleaseInputName, string> = {
      'openai-wif-audience': 'openai-audience-value',
      'openai-identity-provider-id': 'openai-provider-value',
      'openai-service-account-id': 'openai-service-account-value',
      'context-file': options.contextInput ?? contextPath,
      'facts-file': options.factsInput ?? factsPath,
      'body-file': options.bodyInput ?? bodyPath,
    };

    for (const name of releaseInputNames) {
      if (name !== options.omitInput) {
        process.env[inputEnvironmentName(name)] = inputValues[name];
      }
    }

    if (!options.unsetRunnerTemp) {
      process.env.RUNNER_TEMP = runnerTemp;
    }

    process.exitCode = undefined;
    process.stderr.write = (chunk: string | Uint8Array) => {
      stderr += chunk.toString();
      return true;
    };

    await run({
      clientFactory: (clientOptions) => {
        clientCreated = true;
        observedOptions = clientOptions;
        return {
          responses: {
            create: () => {
              if (options.modelError) {
                return Promise.reject(options.modelError);
              }
              return Promise.resolve(
                completedResponse(
                  JSON.stringify({
                    description: 'This release improves delivery reliability.',
                    highlights: ['Handles important release paths safely'],
                  }),
                ),
              );
            },
          },
        };
      },
    });

    return {
      body: process.exitCode === undefined ? await readFile(bodyPath, 'utf8') : undefined,
      clientCreated,
      exitCode: process.exitCode,
      observedOptions,
      runnerTemp,
      stderr,
    };
  } finally {
    process.stderr.write = originalStderrWrite;

    for (const [name, value] of previousEnvironment) {
      if (value === undefined) {
        delete process.env[name];
      } else {
        process.env[name] = value;
      }
    }

    process.exitCode = previousExitCode;
    await rm(runnerTemp, { recursive: true, force: true });
  }
}

function assertRedacted(result: RunResult): void {
  assert.doesNotMatch(
    result.stderr,
    /openai-(?:audience|provider|service-account)-value|untrusted|release-session|diagnostics-/u,
  );
  assert.ok(!result.stderr.includes(result.runnerTemp));
}

void test('the OpenAI request is fixed, stateless, tool-free, bounded, and schema constrained', async () => {
  let observedAudience = '';
  let observedOptions: WorkloadIdentityClientOptions | undefined;
  let observedRequest: Record<string, unknown> | undefined;
  const clientFactory = (options: WorkloadIdentityClientOptions): ResponseClient => {
    observedOptions = options;
    return {
      responses: {
        create: async (request) => {
          observedRequest = request as Record<string, unknown>;
          assert.equal(await options.workloadIdentity.provider.getToken(), githubOidcToken);
          return completedResponse(
            JSON.stringify({
              description: 'This release improves delivery reliability.',
              highlights: ['Handles important release paths more safely'],
            }),
            [{ type: 'reasoning', id: 'reasoning-1', summary: [] }],
          );
        },
      },
    };
  };

  const notes = await generateNotes(
    'bounded untrusted context',
    {
      audience: 'https://api.openai.com/v1',
      identityProviderId: 'idp-123',
      serviceAccountId: 'sa-456',
    },
    {
      clientFactory,
      getIDToken: (audience) => {
        observedAudience = audience;
        return Promise.resolve(githubOidcToken);
      },
    },
  );

  assert.equal(observedOptions?.apiKey, null);
  assert.equal(observedOptions?.workloadIdentity.identityProviderId, 'idp-123');
  assert.equal(observedOptions?.workloadIdentity.serviceAccountId, 'sa-456');
  assert.equal(observedOptions?.workloadIdentity.provider.tokenType, 'jwt');
  assert.equal(observedAudience, 'https://api.openai.com/v1');
  assert.deepEqual(notes.highlights, ['Handles important release paths more safely']);
  assert.equal(observedRequest?.model, 'gpt-5.6-luna');
  assert.equal(observedRequest?.store, false);
  assert.deepEqual(observedRequest?.tools, []);
  assert.deepEqual(observedRequest?.reasoning, { effort: 'none' });
  assert.equal(observedRequest?.max_output_tokens, 800);
  assert.match(String(observedRequest?.instructions), /mixed commits.*files absent from that evidence/u);
  assert.deepEqual((observedRequest?.text as Record<string, unknown>).format, {
    type: 'json_schema',
    name: 'release_description',
    strict: true,
    schema: {
      type: 'object',
      properties: {
        description: { type: 'string', minLength: 1, maxLength: 1_200 },
        highlights: {
          type: 'array',
          minItems: 1,
          maxItems: 6,
          items: { type: 'string', minLength: 1, maxLength: 240 },
        },
      },
      required: ['description', 'highlights'],
      additionalProperties: false,
    },
  });
});

void test('the real OpenAI client reports and classifies workload identity exchange failures safely', async () => {
  const diagnostics: DiagnosticEvent[] = [];
  const fetch: typeof globalThis.fetch = () =>
    Promise.resolve(
      new Response('{"error":"untrusted-token-exchange-detail"}', {
        status: 403,
        headers: { 'content-type': 'application/json' },
      }),
    );

  await assert.rejects(
    generateNotes(
      'untrusted-repository-context',
      {
        audience: 'https://api.openai.com/v1',
        identityProviderId: 'idp-123',
        serviceAccountId: 'sa-456',
      },
      {
        fetch,
        getIDToken: () => Promise.resolve(githubOidcToken),
        reportDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
      },
    ),
    (error) => {
      assert.ok(error instanceof SafeActionFailure);
      assert.deepEqual(error.diagnostic, {
        category: 'workload-identity',
        reason: 'openai-token-exchange-failed',
      });
      return true;
    },
  );

  assert.deepEqual(diagnostics, [
    { stage: 'github-oidc-token', event: 'started' },
    { stage: 'github-oidc-token', event: 'claims', claims: githubOidcClaims },
    { stage: 'github-oidc-token', event: 'succeeded' },
    { stage: 'openai-token-exchange', event: 'started', attempt: 1 },
    { stage: 'openai-token-exchange', event: 'http-response', attempt: 1, httpStatus: 403 },
  ]);
  assert.doesNotMatch(JSON.stringify(diagnostics), /untrusted|secret|idp-123|sa-456/u);
});

void test('the real OpenAI client distinguishes Responses API failures after a successful exchange', async () => {
  const diagnostics: DiagnosticEvent[] = [];
  const fetch: typeof globalThis.fetch = (input) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;

    if (new URL(url).origin === 'https://auth.openai.com') {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            access_token: 'short-lived-openai-token-secret',
            expires_in: 3_600,
            token_type: 'bearer',
          }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        ),
      );
    }

    return Promise.resolve(
      new Response(
        JSON.stringify({
          error: { message: 'untrusted-api-error-detail', type: 'rate_limit_error', code: 'rate_limit' },
        }),
        { status: 429, headers: { 'content-type': 'application/json' } },
      ),
    );
  };

  await assert.rejects(
    generateNotes(
      'untrusted-repository-context',
      {
        audience: 'https://api.openai.com/v1',
        identityProviderId: 'idp-123',
        serviceAccountId: 'sa-456',
      },
      {
        fetch,
        getIDToken: () => Promise.resolve(githubOidcToken),
        reportDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
      },
    ),
    (error) => {
      assert.ok(error instanceof SafeActionFailure);
      assert.deepEqual(error.diagnostic, {
        category: 'model-generation',
        reason: 'openai-response-request-failed',
      });
      return true;
    },
  );

  assert.deepEqual(diagnostics, [
    { stage: 'github-oidc-token', event: 'started' },
    { stage: 'github-oidc-token', event: 'claims', claims: githubOidcClaims },
    { stage: 'github-oidc-token', event: 'succeeded' },
    { stage: 'openai-token-exchange', event: 'started', attempt: 1 },
    { stage: 'openai-token-exchange', event: 'http-response', attempt: 1, httpStatus: 200 },
    { stage: 'openai-response-request', event: 'started', attempt: 1 },
    { stage: 'openai-response-request', event: 'http-response', attempt: 1, httpStatus: 429 },
    { stage: 'openai-response-request', event: 'started', attempt: 2 },
    { stage: 'openai-response-request', event: 'http-response', attempt: 2, httpStatus: 429 },
    { stage: 'openai-response-request', event: 'started', attempt: 3 },
    { stage: 'openai-response-request', event: 'http-response', attempt: 3, httpStatus: 429 },
  ]);
  assert.doesNotMatch(JSON.stringify(diagnostics), /untrusted|secret|idp-123|sa-456/u);
});

void test('response validation failures use granular secret-safe reason codes', async (context) => {
  const validText = JSON.stringify({ description: 'Valid description', highlights: ['Safe highlight'] });
  const cases = [
    {
      name: 'non-completed response',
      response: { status: 'incomplete', output: [], output_text: 'untrusted-model-output-secret-value' },
      reason: 'openai-response-incomplete',
    },
    {
      name: 'refusal in an additional output item',
      response: {
        status: 'completed',
        output_text: validText,
        output: [
          { type: 'reasoning', id: 'reasoning-1', summary: [] },
          {
            type: 'message',
            role: 'assistant',
            status: 'completed',
            content: [{ type: 'output_text', text: validText }],
          },
          {
            type: 'message',
            role: 'assistant',
            status: 'completed',
            content: [{ type: 'refusal', refusal: 'untrusted-model-output-secret-value' }],
          },
        ],
      },
      reason: 'openai-response-refused',
    },
    {
      name: 'missing output_text',
      response: { status: 'completed', output: [{ type: 'reasoning', id: 'reasoning-1', summary: [] }] },
      reason: 'openai-response-output-text-missing',
    },
    {
      name: 'blank output_text',
      response: { status: 'completed', output: [], output_text: '  \n  ' },
      reason: 'openai-response-output-text-missing',
    },
    {
      name: 'invalid JSON',
      response: completedResponse('untrusted-model-output-secret-value'),
      reason: 'openai-response-json-invalid',
    },
    {
      name: 'invalid generated-note shape',
      response: completedResponse(JSON.stringify({ description: 'Missing highlights' })),
      reason: 'openai-response-notes-invalid',
    },
    {
      name: 'invalid generated-note line',
      response: completedResponse(
        JSON.stringify({ description: 'Line one\nline two', highlights: ['Safe highlight'] }),
      ),
      reason: 'openai-response-notes-invalid',
    },
    {
      name: 'disallowed reference-like content',
      response: completedResponse(
        JSON.stringify({
          description: 'Download v9.9.9 at https://untrusted-model-output-secret-value.example',
          highlights: ['Unsafe output'],
        }),
      ),
      reason: 'openai-response-reference-content-disallowed',
    },
  ] as const;

  for (const failureCase of cases) {
    await context.test(failureCase.name, async () => {
      const diagnostics: DiagnosticEvent[] = [];
      await assert.rejects(
        generateNotes(
          'context',
          {
            audience: 'https://api.openai.com/v1',
            identityProviderId: 'idp-123',
            serviceAccountId: 'sa-456',
          },
          {
            clientFactory: () => ({ responses: { create: () => Promise.resolve(failureCase.response) } }),
            reportDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
          },
        ),
        (error) => {
          assert.ok(error instanceof SafeActionFailure);
          assert.deepEqual(error.diagnostic, { category: 'model-generation', reason: failureCase.reason });
          assert.equal(error.message, 'create-release failed');
          assert.doesNotMatch(error.message, /untrusted|context|output-secret/u);
          return true;
        },
      );
      assert.deepEqual(diagnostics, [{ stage: 'openai-response-validation', event: 'started' }]);
      assert.doesNotMatch(JSON.stringify(diagnostics), /untrusted|secret|context/u);
    });
  }
});

void test('local validation requires exact fields, printable lines, and safe descriptive prose', () => {
  assert.deepEqual(
    validateGeneratedNotes({
      description: 'A concise release description',
      highlights: ['Improves predictable behavior'],
    }),
    {
      description: 'A concise release description',
      highlights: ['Improves predictable behavior'],
    },
  );

  assert.throws(() =>
    validateGeneratedNotes({
      description: 'A concise release description',
      highlights: ['Improves predictable behavior'],
      tag: 'v1.0.0',
    }),
  );

  assert.throws(() =>
    validateGeneratedNotes({
      description: 'A line\nbreak',
      highlights: ['Improves predictable behavior'],
    }),
  );

  assert.throws(() =>
    validateGeneratedNotes({
      description: 'A concise release description',
      highlights: ['See Owner/Project for details'],
    }),
  );
});
