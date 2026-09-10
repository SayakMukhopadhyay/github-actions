import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { afterEach, test } from 'node:test';
import { parse } from 'yaml';
import {
  ARGOCD_LINUX_AMD64_SHA256,
  ARGOCD_LINUX_AMD64_URL,
  ARGOCD_VERSION,
  writeVerifiedDownload,
} from '../actions/argocd-verify-deployment/argocd-verify-deployment.ts';

interface ActionStep {
  env?: Record<string, unknown>;
  uses?: unknown;
  with?: Record<string, unknown>;
}

interface ActionMetadata {
  inputs?: Record<string, { default?: unknown; required?: unknown }>;
  outputs?: Record<string, { value?: unknown }>;
  runs?: { steps?: ActionStep[]; using?: unknown };
}

const root = path.resolve(import.meta.dirname, '..');
const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

function temporaryDirectory(): string {
  const directory = mkdtempSync(path.join(tmpdir(), 'argocd-verify-deployment-'));
  temporaryDirectories.push(directory);
  return directory;
}

void test('pins the Argo CD Linux amd64 release URL and checksum', () => {
  assert.equal(ARGOCD_VERSION, 'v3.5.2');
  assert.equal(
    ARGOCD_LINUX_AMD64_URL,
    'https://github.com/argoproj/argo-cd/releases/download/v3.5.2/argocd-linux-amd64',
  );
  assert.equal(ARGOCD_LINUX_AMD64_SHA256, 'd87058531d2aed735100636dd7664bdd49b862588993b571385c49494f9832c1');
  assert.doesNotMatch(ARGOCD_LINUX_AMD64_URL, /\/latest\//u);
});

void test('writes a download only after its pinned checksum matches', async () => {
  const body = 'verified fixture binary';
  const destination = path.join(temporaryDirectory(), 'argocd');

  await writeVerifiedDownload({
    destination,
    expectedSha256: createHash('sha256').update(body).digest('hex'),
    fetchImplementation: () => Promise.resolve(new Response(body)),
    url: 'https://fixture.invalid/argocd',
  });

  assert.equal(readFileSync(destination, 'utf8'), body);
});

void test('removes a download whose checksum does not match', async () => {
  const destination = path.join(temporaryDirectory(), 'argocd');
  await assert.rejects(
    writeVerifiedDownload({
      destination,
      expectedSha256: '0'.repeat(64),
      fetchImplementation: () => Promise.resolve(new Response('tampered fixture binary')),
      url: 'https://fixture.invalid/argocd',
    }),
    /checksum mismatch/u,
  );

  assert.equal(existsSync(destination), false);
});

void test('keeps the public action contract narrow and read-only', () => {
  const metadata = parse(
    readFileSync(path.join(root, 'argocd-verify-deployment', 'action.yaml'), 'utf8'),
  ) as ActionMetadata;

  assert.deepEqual(Object.keys(metadata.inputs ?? {}).sort(), [
    'application',
    'auth-token',
    'cloudflare-access-client-id',
    'cloudflare-access-client-secret',
    'expected-commit-sha',
    'gitops-repository',
    'gitops-token',
    'server',
    'smoke-url',
    'timeout-seconds',
  ]);
  assert.equal(metadata.inputs?.['timeout-seconds']?.default, '300');
  assert.equal(metadata.inputs?.['smoke-url']?.default, '');
  assert.equal(metadata.outputs?.['synchronized-revision']?.value, '${{ steps.verify.outputs.synchronized-revision }}');

  const steps = metadata.runs?.steps ?? [];
  assert.equal(metadata.runs?.using, 'composite');
  assert.equal(steps[0]?.uses, 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1');
  assert.equal(steps[0]?.with?.['fetch-depth'], 0);
  assert.equal(steps[0]?.with?.['persist-credentials'], false);
  assert.equal(steps[1]?.uses, '$/actions/argocd-verify-deployment');

  const transaction = readFileSync(path.join(root, 'argocd-verify-deployment', 'VerifyDeployment.psm1'), 'utf8');

  assert.match(transaction, /--grpc-web/u);
  assert.match(transaction, /CF-Access-Client-Id/u);
  assert.match(transaction, /CF-Access-Client-Secret/u);
  assert.match(transaction, /merge-base.+--is-ancestor/su);
  assert.doesNotMatch(
    transaction,
    /\bapp (?:sync|refresh)\b|\bgit(?:\s+-C\s+"[^"]+")?\s+(?:commit|push)\b|\bkubectl\b/u,
  );
});
