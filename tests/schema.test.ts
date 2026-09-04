import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test, { before } from 'node:test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Ajv } from 'ajv';
import { generateActionSchema } from '../tooling/generate-action-schema.ts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const schemaPath = path.join(root, 'schemas', 'action-inputs.schema.json');

async function validateWorkflow(workflow: unknown): Promise<boolean> {
  const schema = JSON.parse(await readFile(schemaPath, 'utf8')) as object;
  const ajv = new Ajv({ allErrors: true, strict: false });
  return ajv.compile(schema)(workflow);
}

function workflowFor(uses: string, withInputs: Record<string, string> = {}): object {
  return {
    jobs: {
      test: {
        steps: [{ uses, with: withInputs }],
      },
    },
  };
}

void before(async () => {
  await generateActionSchema(root);
});

void test('accepts valid inputs for each documented consumer action', async () => {
  const validActions: [string, Record<string, string>][] = [
    ['check-version', {}],
    ['is-file-changed', { pattern: '^charts/' }],
    ['bump-version', { token: '${{ secrets.GITHUB_TOKEN }}' }],
    ['checkout-dependencies', { 'go-version': '1.24' }],
    ['container-build-push', { version: '1.2.3' }],
    ['helm-package-push', {}],
    [
      'chart-update-deploy',
      {
        token: '${{ secrets.GITHUB_TOKEN }}',
        environment: 'production',
        'chart-name': 'api',
        'chart-version': '1.2.3',
        dependency: 'api',
        'target-repository': 'example/gitops',
      },
    ],
    [
      'create-release',
      {
        token: '${{ secrets.GITHUB_TOKEN }}',
        'tag-name': 'v1.2.3',
        'release-name': 'v1.2.3',
        'openai-api-key': '${{ secrets.OPENAI_API_KEY }}',
      },
    ],
  ];

  for (const [action, withInputs] of validActions) {
    assert.equal(
      await validateWorkflow(
        workflowFor(`SayakMukhopadhyay/github-actions/${action}@v1`, withInputs),
      ),
      true,
      action,
    );
  }
});

void test('rejects an unknown action input', async () => {
  assert.equal(
    await validateWorkflow(
      workflowFor('SayakMukhopadhyay/github-actions/check-version@v1', {
        unexpected: 'value',
      }),
    ),
    false,
  );
});

void test('rejects a missing caller-required action input', async () => {
  assert.equal(
    await validateWorkflow(workflowFor('SayakMukhopadhyay/github-actions/is-file-changed@v1')),
    false,
  );
});

void test('permits metadata inputs that are required but have a default', async () => {
  assert.equal(
    await validateWorkflow(
      workflowFor('SayakMukhopadhyay/github-actions/bump-version@v1', {
        token: '${{ secrets.GITHUB_TOKEN }}',
      }),
    ),
    true,
  );
});
