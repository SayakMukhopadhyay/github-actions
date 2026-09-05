import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import {
  formatActionFailure,
  generateNotes,
  renderReleaseBody,
  run,
  validateGeneratedNotes,
  validateReleaseFacts,
  type ReleaseFacts,
  type ResponseClient,
} from '../actions/create-release/create-release.ts';

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

void test('GitHub-normalized hyphenated action inputs reach the release-note generator', async () => {
  const runnerTemp = await mkdtemp(join(tmpdir(), 'create-release-inputs-'));
  const sessionDirectory = join(runnerTemp, 'release-session');
  const contextPath = join(sessionDirectory, 'context.txt');
  const factsPath = join(sessionDirectory, 'facts.json');
  const bodyPath = join(sessionDirectory, 'body.md');
  const environmentNames = [
    'INPUT_OPENAI_API_KEY',
    'INPUT_CONTEXT_FILE',
    'INPUT_FACTS_FILE',
    'INPUT_BODY_FILE',
    'RUNNER_TEMP',
  ] as const;
  const previousEnvironment = new Map(environmentNames.map((name) => [name, process.env[name]]));
  const previousExitCode = process.exitCode;

  try {
    await mkdir(sessionDirectory);
    await writeFile(contextPath, 'bounded untrusted context', 'utf8');
    await writeFile(factsPath, JSON.stringify(facts), 'utf8');
    process.env.INPUT_OPENAI_API_KEY = 'openai-secret';
    process.env.INPUT_CONTEXT_FILE = contextPath;
    process.env.INPUT_FACTS_FILE = factsPath;
    process.env.INPUT_BODY_FILE = bodyPath;
    process.env.RUNNER_TEMP = runnerTemp;
    process.exitCode = undefined;

    let observedKey = '';
    await run((apiKey) => {
      observedKey = apiKey;
      return {
        responses: {
          create: () =>
            Promise.resolve(
              completedResponse(
                JSON.stringify({
                  description: 'This release improves delivery reliability.',
                  highlights: ['Handles important release paths more safely'],
                }),
              ),
            ),
        },
      };
    });

    assert.equal(process.exitCode, undefined);
    assert.equal(observedKey, 'openai-secret');
    assert.match(await readFile(bodyPath, 'utf8'), /^This release improves delivery reliability\./u);
  } finally {
    for (const [name, value] of previousEnvironment) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    process.exitCode = previousExitCode;
    await rm(runnerTemp, { recursive: true, force: true });
  }
});

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

  assert.deepEqual(
    validateGeneratedNotes({
      description: 'This release improves CI/CD reliability.',
      highlights: ['Makes CI/CD publishing failures easier to diagnose'],
    }),
    {
      description: 'This release improves CI/CD reliability.',
      highlights: ['Makes CI/CD publishing failures easier to diagnose'],
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

void test('prose exception does not weaken generated-content protections', () => {
  const disallowedCases = [
    ['See Owner/Project for details', 'repository-path-or-coordinate'],
    ['Updates src/release.ts', 'repository-path-or-coordinate'],
    ['Reads /etc/release-notes', 'repository-path-or-coordinate'],
    ['Reads C:\\release\\notes', 'repository-path-or-coordinate'],
    ['Publishes ghcr.io/owner/image:tag', 'repository-path-or-coordinate'],
    ['Publishes CI/CD/release', 'repository-path-or-coordinate'],
    ['Publishes ci/cd', 'repository-path-or-coordinate'],
    ['Uses @scope/package', 'package-or-mention'],
    ['Read [the notes](release-notes)', 'markdown'],
    ['Download from https://example.invalid', 'url'],
    ['Targets v1.2.3', 'version'],
    ['Includes commit deadbee', 'commit-id'],
  ] as const;

  for (const [disallowedText, expectedReason] of disallowedCases) {
    assert.throws(
      () =>
        validateGeneratedNotes({
          description: 'A concise release description',
          highlights: [disallowedText],
        }),
      (error: unknown) => formatActionFailure(error, 'model-generation').includes(`reason=${expectedReason}`),
    );
  }
});

void test('failure logging exposes only safe categories and validation reasons', () => {
  let validationError: unknown;
  try {
    validateGeneratedNotes({
      description: 'A concise release description',
      highlights: ['See Owner/Project for details'],
    });
  } catch (error) {
    validationError = error;
  }

  assert.equal(
    formatActionFailure(validationError, 'model-generation'),
    'create-release: failed: category=generated-content-validation reason=repository-path-or-coordinate\n',
  );
  assert.equal(
    formatActionFailure(new Error('untrusted model output and secret values'), 'model-generation'),
    'create-release: failed: category=model-generation reason=operation-failed\n',
  );
});

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
  const source = await readFile(new URL('../actions/create-release/create-release.ts', import.meta.url), 'utf8');

  assert.doesNotMatch(source, /node:child_process|\bexec(?:File|Sync)?\b|\bspawn(?:Sync)?\b/u);
});
