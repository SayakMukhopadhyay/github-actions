import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { parse } from 'yaml';

interface ActionInput {
  default?: unknown;
  description?: unknown;
  required?: unknown;
}

interface ActionOutput {
  description?: unknown;
  value?: unknown;
}

interface ActionStep {
  env?: Record<string, unknown>;
  id?: unknown;
  run?: unknown;
  shell?: unknown;
  uses?: unknown;
  with?: Record<string, unknown>;
}

interface ActionMetadata {
  inputs?: Record<string, ActionInput>;
  outputs?: Record<string, ActionOutput>;
  runs?: {
    main?: unknown;
    steps?: ActionStep[];
    using?: unknown;
  };
}

interface WorkflowStep {
  uses?: unknown;
  with?: Record<string, unknown>;
}

interface WorkflowMetadata {
  jobs?: Record<string, { steps?: WorkflowStep[] }>;
}

const root = path.resolve(import.meta.dirname, '..');
const immutableAction = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[0-9a-f]{40}$/u;
const internalAction = /^\$\/actions\/[a-z0-9-]+$/u;
function readYaml<T>(file: string): T {
  return parse(readFileSync(file, 'utf8')) as T;
}

function readAction(name: string): ActionMetadata {
  return readYaml<ActionMetadata>(path.join(root, name, 'action.yaml'));
}

function consumerActionNames(): string[] {
  return readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .filter((entry) => {
      try {
        return readFileSync(path.join(root, entry.name, 'action.yaml')).length > 0;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false;
        throw error;
      }
    })
    .map((entry) => entry.name)
    .sort((left, right) => left.localeCompare(right));
}

void test('consumer action metadata is complete and uses safe runtime boundaries', () => {
  const actionNames = consumerActionNames();
  assert.notEqual(actionNames.length, 0, 'expected at least one reusable action');

  const readme = readFileSync(path.join(root, 'README.md'), 'utf8');
  for (const actionName of actionNames) {
    const metadata = readAction(actionName);
    assert.equal(
      metadata.runs?.using === 'node24' || metadata.runs?.using === 'composite',
      true,
      `${actionName} runtime`,
    );
    if (metadata.runs?.using === 'node24') {
      assert.equal(metadata.runs?.main, 'dist/index.mjs', `${actionName} bundle entry`);
    }

    for (const [inputName, input] of Object.entries(metadata.inputs ?? {})) {
      assert.equal(typeof input.description, 'string', `${actionName}.${inputName} description`);
      assert.notEqual(input.description, '', `${actionName}.${inputName} description`);
      assert.equal(typeof input.required, 'boolean', `${actionName}.${inputName} required`);
    }
    for (const [outputName, output] of Object.entries(metadata.outputs ?? {})) {
      assert.equal(typeof output.description, 'string', `${actionName}.${outputName} description`);
      assert.notEqual(output.description, '', `${actionName}.${outputName} description`);
      assert.equal(typeof output.value, 'string', `${actionName}.${outputName} value`);
      assert.notEqual(output.value, '', `${actionName}.${outputName} value`);
    }

    assert.match(
      readme,
      new RegExp(`SayakMukhopadhyay/github-actions/${actionName}@v1`, 'u'),
      `${actionName} README reference`,
    );

    for (const step of metadata.runs?.steps ?? []) {
      if (typeof step.uses === 'string') {
        assert.equal(
          immutableAction.test(step.uses) || internalAction.test(step.uses),
          true,
          `${actionName} action reference is not immutable or repository-internal: ${step.uses}`,
        );
      }
      if (step.run !== undefined) {
        assert.equal(typeof step.shell, 'string', `${actionName} run step needs an explicit shell`);
        assert.notEqual(step.shell, '', `${actionName} run step needs an explicit shell`);
      }
    }
  }
});

void test('container build metadata preserves safe optional forwarding', () => {
  const metadata = readAction('container-build-push');
  assert.equal(metadata.inputs?.['build-args']?.default, '');
  const buildSteps = (metadata.runs?.steps ?? []).filter(
    (step) => typeof step.uses === 'string' && step.uses.startsWith('docker/build-push-action@'),
  );
  assert.equal(buildSteps.length, 1);
  assert.equal(buildSteps[0]?.with?.['build-args'], '${{ inputs.build-args }}');
});

void test('release-tags fixes the target and keeps Git credentials ephemeral', () => {
  const metadata = readAction('release-tags');
  assert.equal(metadata.inputs?.token?.required, true);
  assert.equal(metadata.inputs?.tags?.required, true);
  assert.equal(metadata.inputs?.mode?.default, 'verify');
  assert.match(String(metadata.inputs?.mode?.description), /\bexists\b/u);
  assert.equal(metadata.outputs?.['tags-exist']?.value, '${{ steps.tags.outputs.tags-exist }}');
  assert.match(String(metadata.outputs?.['tags-exist']?.description), /every requested tag exists/u);
  assert.equal(metadata.outputs?.['tags-match']?.value, '${{ steps.tags.outputs.tags-match }}');
  assert.match(String(metadata.outputs?.['tags-match']?.description), /verify or ensure mode/u);

  const checkoutSteps = (metadata.runs?.steps ?? []).filter(
    (step) => typeof step.uses === 'string' && step.uses.startsWith('actions/checkout@'),
  );
  assert.equal(checkoutSteps.length, 1);
  assert.equal(checkoutSteps[0]?.with?.ref, '${{ github.sha }}');
  assert.equal(checkoutSteps[0]?.with?.['fetch-tags'], false);
  assert.equal(checkoutSteps[0]?.with?.['persist-credentials'], false);

  const transactionSteps = (metadata.runs?.steps ?? []).filter((step) => step.id === 'tags');
  assert.equal(transactionSteps.length, 1);
  assert.equal(transactionSteps[0]?.env?.INPUT_TOKEN, '${{ inputs.token }}');
  assert.equal(transactionSteps[0]?.env?.TARGET_SHA, '${{ github.sha }}');

  const transaction = readFileSync(path.join(root, 'release-tags', 'release-tags.sh'), 'utf8');
  assert.match(transaction, /unset INPUT_TOKEN/u);
  assert.match(transaction, /git_remote push --atomic --no-force/u);
  assert.doesNotMatch(transaction, /git tag/u);
});

void test('CI exercises multiline container build arguments through the consumer action', () => {
  const workflow = readYaml<WorkflowMetadata>(path.join(root, '.github', 'workflows', 'ci.yaml'));
  const steps = workflow.jobs?.['action-level']?.steps ?? [];
  const fixtures = steps.filter((step) => step.uses === '$/container-build-push');
  assert.equal(fixtures.length, 1);
  assert.equal(fixtures[0]?.with?.['build-args'], 'VERSION=fixture-version\nCOMMIT=fixture-commit\n');
});
