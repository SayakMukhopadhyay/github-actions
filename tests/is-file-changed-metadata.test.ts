import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { parse } from 'yaml';

interface ActionMetadata {
  inputs?: Record<string, { required?: boolean }>;
  runs?: {
    steps?: {
      env?: Record<string, string>;
      uses?: string;
      with?: Record<string, string>;
    }[];
  };
}

const actionPath = path.join(import.meta.dirname, '..', 'is-file-changed', 'action.yaml');

void test('is-file-changed metadata exposes and wires paired explicit refs', async () => {
  const metadata = parse(await readFile(actionPath, 'utf8')) as ActionMetadata;

  assert.equal(metadata.inputs?.['base-ref']?.required, false);
  assert.equal(metadata.inputs?.['head-ref']?.required, false);

  const steps = metadata.runs?.steps ?? [];
  const validation = steps.find((step) => step.env?.ACTION_PATH !== undefined);
  const checkout = steps.find((step) => step.uses?.startsWith('actions/checkout@'));
  const collection = steps.find((step) => step.env?.ACTION_PATH !== undefined && step !== validation);

  assert.equal(validation?.env?.BASE_REF, '${{ inputs.base-ref }}');
  assert.equal(validation?.env?.HEAD_REF, '${{ inputs.head-ref }}');
  assert.equal(checkout?.with?.ref, '${{ inputs.head-ref || github.event.after }}');
  assert.equal(collection?.env?.BASE_REF, '${{ inputs.base-ref }}');
  assert.equal(collection?.env?.HEAD_REF, '${{ inputs.head-ref }}');
});
