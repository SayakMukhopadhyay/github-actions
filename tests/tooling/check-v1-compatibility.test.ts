import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { checkV1Compatibility } from '../../tooling/check-v1-compatibility.ts';

const metadata = (inputs: string, outputs = '') => `name: Example
inputs:
${inputs}
outputs:
${outputs}`;

async function writeAction(root: string, name: string, source: string): Promise<void> {
  const directory = path.join(root, name);
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, 'action.yaml'), source, 'utf8');
}

async function withActionTrees(
  callback: (baseline: string, current: string) => Promise<void>,
): Promise<void> {
  const temporary = await mkdtemp(path.join(tmpdir(), 'github-actions-contracts-'));
  const baseline = path.join(temporary, 'baseline');
  const current = path.join(temporary, 'current');
  await mkdir(baseline);
  await mkdir(current);
  try {
    await callback(baseline, current);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

void test('permits an additive optional input and output', async () => {
  await withActionTrees(async (baseline, current) => {
    await writeAction(
      baseline,
      'example',
      metadata('  token:\n    required: true\n', '  result:\n    description: Result\n'),
    );
    await writeAction(
      current,
      'example',
      metadata(
        '  token:\n    required: true\n  optional:\n    required: false\n',
        '  result:\n    description: Result\n  detail:\n    description: Detail\n',
      ),
    );

    await checkV1Compatibility(baseline, current);
  });
});

void test('rejects a changed default without invoking git', async () => {
  await withActionTrees(async (baseline, current) => {
    await writeAction(
      baseline,
      'example',
      metadata('  mode:\n    required: false\n    default: safe\n'),
    );
    await writeAction(
      current,
      'example',
      metadata('  mode:\n    required: false\n    default: unsafe\n'),
    );

    await assert.rejects(
      checkV1Compatibility(baseline, current),
      /default changed or was removed/u,
    );
  });
});
