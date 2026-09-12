import assert from 'node:assert/strict';
import { access, readdir, readFile } from 'node:fs/promises';
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

async function consumerActionNames(): Promise<string[]> {
  const entries = await readdir(root, { withFileTypes: true });
  const candidates = entries.filter((entry) => entry.isDirectory());
  const actionNames = await Promise.all(
    candidates.map(async (entry) => {
      try {
        await access(path.join(root, entry.name, 'action.yaml'));
        return entry.name;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
          return undefined;
        }
        throw error;
      }
    }),
  );

  return actionNames
    .filter((actionName): actionName is string => actionName !== undefined)
    .sort((left, right) => left.localeCompare(right));
}

void before(async () => {
  await generateActionSchema(root);
});

void test('accepts valid inputs for each documented consumer action', async () => {
  const validActions: [string, Record<string, string>][] = [
    ['check-version', {}],
    ['is-file-changed', { pattern: '^charts/', 'base-ref': 'chart-v1.2.3', 'head-ref': 'main' }],
    ['bump-version', { token: '${{ secrets.GITHUB_TOKEN }}', increment: 'patch' }],
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
    ['container-build-push', { version: 'build-abcdef' }],
    ['container-image-inspect', { version: 'build-abcdef' }],
    [
      'container-promote',
      {
        'source-digest': 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        tag: 'v1.2.3',
        username: '${{ github.actor }}',
        password: '${{ secrets.GITHUB_TOKEN }}',
      },
    ],
    ['helm-package-push', { development: 'true' }],
    [
      'argocd-verify-deployment',
      {
        server: 'argocd.example.com',
        application: 'api-production',
        'auth-token': '${{ secrets.ARGOCD_AUTH_TOKEN }}',
        'cloudflare-access-client-id': '${{ secrets.CF_ACCESS_CLIENT_ID }}',
        'cloudflare-access-client-secret': '${{ secrets.CF_ACCESS_CLIENT_SECRET }}',
        'expected-commit-sha': '${{ needs.promote.outputs.commit-sha }}',
        'gitops-repository': 'SayakMukhopadhyay/k8s-landscape-charts',
        'gitops-token': '${{ secrets.GITOPS_READ_TOKEN }}',
      },
    ],
    [
      'chart-update-deploy',
      {
        token: '${{ secrets.GITHUB_TOKEN }}',
        environment: 'production',
        'chart-name': 'api',
        'image-tag': 'build-abcdef1234567890',
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
  const fixtureActionNames = validActions.map(([action]) => action);

  assert.equal(new Set(fixtureActionNames).size, fixtureActionNames.length, 'consumer action fixtures must be unique');
  assert.deepEqual(
    fixtureActionNames.toSorted((left, right) => left.localeCompare(right)),
    await consumerActionNames(),
    'consumer action fixtures must exactly cover every root-level action',
  );

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

void test('rejects the private Helm package source revision input', async () => {
  assert.equal(
    await validateWorkflow(
      workflowFor('SayakMukhopadhyay/github-actions/helm-package-push@v1', {
        'source-revision': 'abcdef1234567890abcdef1234567890abcdef12',
      }),
    ),
    false,
  );
});

void test('rejects a missing caller-required action input', async () => {
  assert.equal(await validateWorkflow(workflowFor('SayakMukhopadhyay/github-actions/is-file-changed@v1')), false);
});

void test('rejects missing required Argo CD deployment verification inputs', async () => {
  assert.equal(
    await validateWorkflow(
      workflowFor('SayakMukhopadhyay/github-actions/argocd-verify-deployment@v1', {
        server: 'argocd.example.com',
        application: 'api-production',
      }),
    ),
    false,
  );
});

void test('rejects a missing required bump-version increment', async () => {
  assert.equal(
    await validateWorkflow(
      workflowFor('SayakMukhopadhyay/github-actions/bump-version@v1', {
        token: '${{ secrets.GITHUB_TOKEN }}',
      }),
    ),
    false,
  );
});

void test('rejects missing required container promotion credentials', async () => {
  assert.equal(
    await validateWorkflow(
      workflowFor('SayakMukhopadhyay/github-actions/container-promote@v1', {
        'source-digest': 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        tag: 'v1.2.3',
      }),
    ),
    false,
  );
});
