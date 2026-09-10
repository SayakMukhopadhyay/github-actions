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

void test('run reports safe diagnostics without changing action input lookup or exposing values', async (context) => {
  await context.test('the existing hyphenated input environment names reach generation', async () => {
    const result = await exerciseRun();

    assert.equal(result.exitCode, undefined);
    assert.equal(result.stderr, '');
    assert.equal(result.observedKey, 'openai-secret-value');
    assert.match(result.body ?? '', /^This release improves delivery reliability\./u);
  });

  for (const input of releaseInputNames) {
    await context.test(`a missing ${input} input reports only its fixed label`, async () => {
      const result = await exerciseRun({ omitInput: input });

      assert.equal(result.clientCreated, false);
      assert.equal(result.exitCode, 1);
      assert.equal(
        result.stderr,
        `create-release: failed: category=input-validation reason=missing-required-input input=${input}\n`,
      );
      assertRedacted(result);
    });
  }

  await context.test('missing RUNNER_TEMP has a fixed reason', async () => {
    const result = await exerciseRun({ unsetRunnerTemp: true });

    assert.equal(result.clientCreated, false);
    assert.equal(result.exitCode, 1);
    assert.equal(result.stderr, 'create-release: failed: category=input-validation reason=missing-runner-temp\n');
    assertRedacted(result);
  });

  await context.test('context path validation reports only the file role', async () => {
    const result = await exerciseRun({
      contextInput: join(tmpdir(), 'untrusted-context-secret-value-does-not-exist'),
    });

    assert.equal(result.clientCreated, false);
    assert.equal(result.exitCode, 1);
    assert.equal(result.stderr, 'create-release: failed: category=input-file-validation reason=context-file\n');
    assertRedacted(result);
  });

  await context.test('facts path validation reports only the file role', async () => {
    const result = await exerciseRun({
      factsInput: join(tmpdir(), 'untrusted-facts-secret-value-does-not-exist'),
    });

    assert.equal(result.clientCreated, false);
    assert.equal(result.exitCode, 1);
    assert.equal(result.stderr, 'create-release: failed: category=input-file-validation reason=facts-file\n');
    assertRedacted(result);
  });

  await context.test('body path validation reports only the file role', async () => {
    const result = await exerciseRun({
      bodyInput: join(tmpdir(), 'untrusted-body-secret-value.md'),
    });

    assert.equal(result.clientCreated, false);
    assert.equal(result.exitCode, 1);
    assert.equal(result.stderr, 'create-release: failed: category=input-file-validation reason=body-file\n');
    assertRedacted(result);
  });

  await context.test('malformed release facts have one fixed safe reason', async () => {
    const result = await exerciseRun({ factsContent: '{"untrusted-facts-secret-value":' });

    assert.equal(result.clientCreated, false);
    assert.equal(result.exitCode, 1);
    assert.equal(result.stderr, 'create-release: failed: category=release-facts-validation reason=invalid-facts\n');
    assertRedacted(result);
  });

  await context.test('structurally invalid release facts have the same fixed safe reason', async () => {
    const result = await exerciseRun({
      factsContent: JSON.stringify({ ...facts, repository: 'untrusted-facts-secret-value' }),
    });

    assert.equal(result.clientCreated, false);
    assert.equal(result.exitCode, 1);
    assert.equal(result.stderr, 'create-release: failed: category=release-facts-validation reason=invalid-facts\n');
    assertRedacted(result);
  });

  await context.test('model failures expose neither the operation error nor supplied content', async () => {
    const result = await exerciseRun({
      modelError: new Error('openai-secret-value untrusted-context-secret-value model-output-secret-value'),
    });

    assert.equal(result.clientCreated, true);
    assert.equal(result.exitCode, 1);
    assert.equal(result.stderr, 'create-release: failed: category=model-generation reason=operation-failed\n');
    assertRedacted(result);
    assert.doesNotMatch(result.stderr, /model-output-secret-value/u);
  });

  await context.test('rendering failures expose only their operation category', async () => {
    const result = await exerciseRun({ factsContent: JSON.stringify({ ...facts, tagName: '\ud800' }) });

    assert.equal(result.clientCreated, true);
    assert.equal(result.exitCode, 1);
    assert.equal(result.stderr, 'create-release: failed: category=rendering reason=operation-failed\n');
    assertRedacted(result);
  });

  await context.test('output write failures expose only their operation category', async () => {
    const result = await exerciseRun({ precreateBody: true });

    assert.equal(result.clientCreated, true);
    assert.equal(result.exitCode, 1);
    assert.equal(result.stderr, 'create-release: failed: category=output-write reason=operation-failed\n');
    assertRedacted(result);
  });
});

void test('consumer composite scopes GitHub and OpenAI credentials to different processes', async () => {
  const metadata = await readFile(new URL('../create-release/action.yaml', import.meta.url), 'utf8');

  const contextStep = metadata.slice(metadata.indexOf('- id: context'), metadata.indexOf('- id: preflight'));
  const preflightStep = metadata.slice(
    metadata.indexOf('- id: preflight'),
    metadata.indexOf('- name: Generate and render'),
  );
  const generatorStep = metadata.slice(
    metadata.indexOf('- name: Generate and render'),
    metadata.indexOf('- id: publish'),
  );
  const publisherStep = metadata.slice(metadata.indexOf('- id: publish'));
  const cleanupStep = metadata.slice(metadata.indexOf('- name: Clean up release session'));

  assert.doesNotMatch(contextStep, /inputs\.(?:token|openai-api-key)/u);
  assert.match(contextStep, /INPUT_PATHSPECS: \$\{\{ inputs\.pathspecs \}\}/u);
  assert.match(preflightStep, /inputs\.token/u);
  assert.doesNotMatch(preflightStep, /inputs\.openai-api-key/u);
  assert.match(generatorStep, /inputs\.openai-api-key/u);
  assert.doesNotMatch(generatorStep, /inputs\.token/u);
  assert.match(publisherStep, /inputs\.token/u);
  assert.doesNotMatch(publisherStep, /inputs\.openai-api-key/u);
  assert.match(cleanupStep, /if: always\(\)/u);
  assert.match(cleanupStep, /steps\.context\.outputs\.session-directory/u);
  assert.doesNotMatch(cleanupStep, /inputs\.(?:token|openai-api-key)/u);
  assert.match(metadata, /fetch-depth: 0/u);
  assert.match(metadata, /fetch-tags: true/u);
});

void test('create-release TypeScript never invokes external commands', async () => {
  const source = await readFile(new URL('../actions/create-release/src/openai.ts', import.meta.url), 'utf8');

  assert.doesNotMatch(source, /node:child_process|\bexec(?:File|Sync)?\b|\bspawn(?:Sync)?\b/u);
});
