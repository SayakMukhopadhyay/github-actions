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
  validateGeneratedNotes,
  validateReleaseFacts,
  type ReleaseFacts,
  type ResponseClient,
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

function completedResponse(text: string): unknown {
  return {
    status: 'completed',
    output: [
      {
        type: 'message',
        role: 'assistant',
        status: 'completed',
        content: [{ type: 'output_text', text }],
      },
    ],
  };
}

const releaseInputNames = ['openai-api-key', 'context-file', 'facts-file', 'body-file'] as const;
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
  observedKey: string;
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
  let observedKey = '';
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
      'openai-api-key': 'openai-secret-value',
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

    await run((apiKey) => {
      clientCreated = true;
      observedKey = apiKey;
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
    });

    return {
      body: process.exitCode === undefined ? await readFile(bodyPath, 'utf8') : undefined,
      clientCreated,
      exitCode: process.exitCode,
      observedKey,
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
  assert.doesNotMatch(result.stderr, /openai-secret-value|untrusted|release-session|diagnostics-/u);
  assert.ok(!result.stderr.includes(result.runnerTemp));
}

void test('the OpenAI request is fixed, stateless, tool-free, bounded, and schema constrained', async () => {
  let observedKey = '';
  let observedRequest: Record<string, unknown> | undefined;
  const clientFactory = (apiKey: string): ResponseClient => {
    observedKey = apiKey;
    return {
      responses: {
        create: (request) => {
          observedRequest = request as Record<string, unknown>;
          return Promise.resolve(
            completedResponse(
              JSON.stringify({
                description: 'This release improves delivery reliability.',
                highlights: ['Handles important release paths more safely'],
              }),
            ),
          );
        },
      },
    };
  };

  const notes = await generateNotes('bounded untrusted context', 'openai-secret', clientFactory);

  assert.equal(observedKey, 'openai-secret');
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

void test('malformed, refused, incomplete, and unsafe model responses fail closed', async () => {
  const responses: unknown[] = [
    { status: 'incomplete', output: [] },
    {
      status: 'completed',
      output: [
        {
          type: 'message',
          role: 'assistant',
          status: 'completed',
          content: [{ type: 'output_text', text: '{"description":"Valid","highlights":["Safe"]}' }],
        },
        { type: 'unexpected_output' },
      ],
    },
    {
      status: 'completed',
      output: [
        {
          type: 'message',
          role: 'assistant',
          status: 'completed',
          content: [{ type: 'refusal', refusal: 'No' }],
        },
      ],
    },
    completedResponse('not JSON'),
    completedResponse(JSON.stringify({ description: 'Missing highlights' })),
    completedResponse(
      JSON.stringify({
        description: 'Download v9.9.9 at https://evil.example',
        highlights: ['Unsafe output'],
      }),
    ),
  ];

  for (const response of responses) {
    await assert.rejects(
      generateNotes('context', 'secret', () => ({
        responses: { create: () => Promise.resolve(response) },
      })),
    );
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
