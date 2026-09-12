import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = path.resolve(import.meta.dirname, '..');

void test('npm owns every Node.js development task', async () => {
  const packageMetadata = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8')) as {
    scripts?: Record<string, string>;
  };
  const scripts = packageMetadata.scripts ?? {};

  assert.equal(scripts.format, 'prettier --write "*" "[!.]*/**/*" ".github/**/*" --ignore-unknown');
  assert.equal(scripts['format:check'], 'prettier --check "*" "[!.]*/**/*" ".github/**/*" --ignore-unknown');
  assert.equal(scripts.lint, 'eslint .');
  assert.match(scripts.typecheck ?? '', /^tsc /u);
  assert.match(scripts.test ?? '', /^node --test /u);
  assert.match(scripts.generate ?? '', /^node tooling\/generate-action-schema\.ts$/u);
  assert.match(scripts.build ?? '', /^rolldown /u);
  assert.match(scripts['check:bundles'] ?? '', /^tsc /u);
  assert.match(scripts['validate:node'] ?? '', /npm run validate:generated/u);
  assert.equal(scripts['validate:powershell'], 'pwsh -NoProfile -File ./build.ps1 Validate');
});

void test('the PowerShell build does not invoke or configure Node.js tools', async () => {
  const source = await readFile(path.join(root, 'build.ps1'), 'utf8');

  assert.doesNotMatch(source, /Invoke-NodeTool/u);
  assert.doesNotMatch(source, /Invoke-Native\s+(?:node|npm)\b/u);
  assert.doesNotMatch(source, /\b(?:prettier|eslint|rolldown|tsc)\b/iu);
  assert.doesNotMatch(source, /'TypeCheck'|'Generate'|'Bundle'/u);
});
