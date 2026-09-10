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

void test('deterministic rendering keeps model prose separate from Git-authoritative facts', () => {
  const body = renderReleaseBody(
    {
      description: 'This release improves clarity & safety.',
      highlights: ['Makes behavior easier to understand'],
    },
    facts,
  );

  assert.match(body, /^This release improves clarity &amp; safety\./u);
  assert.match(body, /## Highlights\n\n- Makes behavior easier to understand/u);
  assert.match(body, /\/commit\/cccccccccccccccccccccccccccccccccccccccc\) Direct mainline change/u);
  assert.match(body, /\\\[links\\\]\\\(https:\/\/evil\.example\\\)/u);
  assert.match(body, /&#64;mentions/u);
  assert.match(body, /\/compare\/charts%2F0\.1\.0\.\.\.charts%2F0\.2\.0\)\n$/u);
});

void test('initial releases render the source link and an empty-range explanation', () => {
  const body = renderReleaseBody(
    { description: 'Initial availability', highlights: ['Establishes the release'] },
    { ...facts, previousTag: null, commits: [], tagName: 'v0.0.1' },
  );

  assert.match(body, /_No mainline commits are present in this tag range\._/u);
  assert.match(body, /\/tree\/v0\.0\.1\)\n$/u);
  assert.doesNotMatch(body, /\/compare\//u);
});

void test('release facts validation rejects injected links and malformed commit authorities', () => {
  assert.deepEqual(validateReleaseFacts(facts), facts);

  assert.throws(() => validateReleaseFacts({ ...facts, repository: 'Owner/Project/extra' }));
  assert.throws(() => validateReleaseFacts({ ...facts, previousTag: '' }));

  assert.throws(() =>
    validateReleaseFacts({
      ...facts,
      commits: [{ sha: 'not-a-sha', subject: 'Untrusted' }],
    }),
  );

  assert.throws(() => validateReleaseFacts({ ...facts, unexpected: true }));

  assert.throws(() =>
    validateReleaseFacts({
      ...facts,
      commits: Array.from({ length: 49 }, (_, index) => ({
        sha: index.toString(16).padStart(40, '0'),
        subject: 'Bounded commit',
      })),
    }),
  );
});

void test('maximum accepted release facts always render within the publisher body limit', () => {
  const maximumFacts = validateReleaseFacts({
    schemaVersion: 1,
    repository: `${'o'.repeat(127)}/${'r'.repeat(128)}`,
    serverUrl: `https://${'s'.repeat(247)}`,
    tagName: '😀'.repeat(255),
    targetObject: 'a'.repeat(64),
    targetCommit: 'b'.repeat(64),
    previousTag: '🚀'.repeat(255),
    previousObject: 'c'.repeat(64),
    commits: Array.from({ length: 48 }, (_, index) => ({
      sha: index.toString(16).padStart(64, '0'),
      subject: '&'.repeat(240),
    })),
    omittedCommitCount: Number.MAX_SAFE_INTEGER,
  });
  const maximumNotes = validateGeneratedNotes({
    description: '&'.repeat(1_200),
    highlights: Array.from({ length: 6 }, () => '&'.repeat(240)),
  });

  const body = renderReleaseBody(maximumNotes, maximumFacts);

  assert.ok(Buffer.byteLength(body, 'utf8') <= 120_000);
});
