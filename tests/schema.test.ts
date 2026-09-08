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
    [
      'checkout-dependencies',
      {
        'go-version': '1.24',
        'go-working-directory': 'api',
        'node-version-file': '.nvmrc',
        'node-working-directory': 'website',
      },
    ],
    [
      'azure-acr-token',
      {
        'client-id': '${{ vars.AZURE_CLIENT_ID }}',
        'tenant-id': '${{ vars.AZURE_TENANT_ID }}',
        'subscription-id': '${{ vars.AZURE_SUBSCRIPTION_ID }}',
        'login-server': '${{ vars.ACR_LOGIN_SERVER }}',
      },
    ],
    ['container-build-push', { version: '1.2.3' }],
    ['helm-package-push', {}],
    [
      'chart-update-deploy',
      {
        token: '${{ secrets.GITHUB_TOKEN }}',
        environment: 'production',
        'chart-name': 'api',
        'chart-version': '1.2.3',
      },
    ],
    [
      'static-site-update-deploy',
      {
        token: '${{ secrets.GITHUB_TOKEN }}',
        environment: 'production',
        'chart-name': 'landscape',
        'image-version': 'build-abcdef1234567890',
      },
    ],
    [
      'create-release',
      {
        token: '${{ secrets.GITHUB_TOKEN }}',
        'tag-name': 'v1.2.3',
        'release-name': 'v1.2.3',
        'openai-api-key': '${{ secrets.OPENAI_API_KEY }}',
        pathspecs: ':(top,glob)**\n:(top,glob,exclude)charts/**',
      },
    ],
    [
      'release-tags',
      {
        token: '${{ secrets.GITHUB_TOKEN }}',
        tags: 'v1.2.3\ncharts/v1.2.3',
      },
    ],
    ['validate-static-site', { path: 'dist' }],
    [
      'dispatch-pages-deployment',
      {
        'github-token': '${{ secrets.PUBLISHER_TOKEN }}',
        'target-repository': 'SayakMukhopadhyay/site-publisher',
        'artifact-name': 'static-site',
      },
    ],
    [
      'deploy-pages-artifact',
      {
        'github-token': '${{ secrets.SOURCE_TOKEN }}',
        'source-repository': 'SayakMukhopadhyay/source-site',
        'source-run-id': '${{ github.event.client_payload.source_run_id }}',
        'artifact-name': 'static-site',
      },
    ],
  ];

  for (const [action, withInputs] of validActions) {
    assert.equal(
      await validateWorkflow(workflowFor(`SayakMukhopadhyay/github-actions/${action}@v1`, withInputs)),
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
  assert.equal(await validateWorkflow(workflowFor('SayakMukhopadhyay/github-actions/is-file-changed@v1')), false);
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
