import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, test, type TestContext } from 'node:test';
import {
  createDispatchPayload,
  dispatchPagesDeployment,
  type GitHubContext,
  type Request,
} from '../dispatch-pages-deployment/dispatch-pages-deployment.ts';
import { validateStaticSite } from '../validate-static-site/validate-static-site.ts';

const temporaryDirectories: string[] = [];
const context: GitHubContext = {
  apiUrl: 'https://api.github.com',
  sourceRepository: 'SayakMukhopadhyay/source-site',
  sourceRunId: '123456789',
  sourceSha: '0123456789abcdef0123456789abcdef01234567',
};

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

function temporaryDirectory(): string {
  const directory = mkdtempSync(join(tmpdir(), 'github-pages-actions-'));
  temporaryDirectories.push(directory);
  return directory;
}

function validSite(): string {
  const site = temporaryDirectory();
  mkdirSync(join(site, 'assets'));
  writeFileSync(join(site, 'index.html'), '<!doctype html><title>Fixture</title>\n');
  writeFileSync(join(site, 'assets', 'site.css'), 'body {}\n');
  return site;
}

function createFileSymlinkOrSkip(testContext: TestContext, target: string, path: string): boolean {
  try {
    symlinkSync(target, path, 'file');
    return true;
  } catch (error) {
    const code = error instanceof Error && 'code' in error ? error.code : undefined;
    if (code === 'EPERM' || code === 'EACCES' || code === 'ENOTSUP') {
      testContext.skip(`file symlinks are unavailable on this platform (${String(code)})`);
      return false;
    }
    throw error;
  }
}

void test('validate-static-site accepts a built directory with nested regular files', async () => {
  await validateStaticSite(validSite());
});

void test('validate-static-site rejects missing, non-directory, empty, and index-less paths', async () => {
  const root = temporaryDirectory();
  await assert.rejects(validateStaticSite(join(root, 'missing')), /path does not exist/u);

  const file = join(root, 'file');
  writeFileSync(file, 'not a directory');
  await assert.rejects(validateStaticSite(file), /must be a directory/u);

  const empty = join(root, 'empty');
  mkdirSync(empty);
  await assert.rejects(validateStaticSite(empty), /directory is empty/u);

  const nestedOnly = join(root, 'nested-only');
  mkdirSync(join(nestedOnly, 'nested'), { recursive: true });
  writeFileSync(join(nestedOnly, 'nested', 'index.html'), '<title>Nested</title>\n');
  await assert.rejects(validateStaticSite(nestedOnly), /root index\.html/u);
});

void test('validate-static-site rejects symbolic links anywhere in the site', async (testContext) => {
  const site = validSite();
  const external = join(temporaryDirectory(), 'external.txt');
  writeFileSync(external, 'external');
  if (!createFileSymlinkOrSkip(testContext, external, join(site, 'assets', 'linked.txt'))) {
    return;
  }
  await assert.rejects(validateStaticSite(site), /must not contain symbolic links.*assets[\\/]linked\.txt/u);
});

void test('dispatch payload is fixed and derives every source field from context', () => {
  assert.deepEqual(createDispatchPayload(context, 'static-site'), {
    event_type: 'deploy-pages',
    client_payload: {
      source_repository: 'SayakMukhopadhyay/source-site',
      source_run_id: '123456789',
      source_sha: '0123456789abcdef0123456789abcdef01234567',
      artifact_name: 'static-site',
    },
  });
});

void test('dispatch sends the fixed request to the validated target repository', async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const request: Request = (url, init) => {
    calls.push({ url, init });
    return Promise.resolve(new Response(null, { status: 204 }));
  };

  await dispatchPagesDeployment(
    { token: 'secret-token', targetRepository: 'SayakMukhopadhyay/publisher', artifactName: 'static-site' },
    context,
    { request },
  );

  assert.equal(calls.length, 1);
  assert.equal(calls[0]?.url, 'https://api.github.com/repos/SayakMukhopadhyay/publisher/dispatches');
  assert.equal(calls[0]?.init.method, 'POST');
  assert.equal(new Headers(calls[0]?.init.headers).get('authorization'), 'Bearer secret-token');
  const requestBody = calls[0]?.init.body;
  if (typeof requestBody !== 'string') {
    assert.fail('expected a JSON string request body');
  }
  assert.deepEqual(JSON.parse(requestBody), createDispatchPayload(context, 'static-site'));
});

void test('dispatch retries transient responses and honors retry-after without leaking bodies', async () => {
  let attempts = 0;
  const delays: number[] = [];
  const request: Request = () => {
    attempts += 1;
    return Promise.resolve(
      attempts === 1
        ? new Response('secret-token from response', { status: 503, headers: { 'retry-after': '2' } })
        : new Response(null, { status: 204 }),
    );
  };

  await dispatchPagesDeployment(
    { token: 'secret-token', targetRepository: 'owner/publisher', artifactName: 'site' },
    context,
    { request, sleep: (delay) => Promise.resolve(delays.push(delay)).then(() => undefined) },
  );
  assert.equal(attempts, 2);
  assert.deepEqual(delays, [2_000]);
});

void test('dispatch retries a GitHub secondary-rate-limit response with retry-after', async () => {
  let attempts = 0;
  const request: Request = () => {
    attempts += 1;
    return Promise.resolve(
      attempts === 1
        ? new Response(null, { status: 403, headers: { 'retry-after': '0' } })
        : new Response(null, { status: 204 }),
    );
  };

  await dispatchPagesDeployment(
    { token: 'secret-token', targetRepository: 'owner/publisher', artifactName: 'site' },
    context,
    { request, sleep: () => Promise.resolve() },
  );
  assert.equal(attempts, 2);
});

void test('dispatch failures report only safe status and request diagnostics', async () => {
  const request: Request = () =>
    Promise.resolve(
      new Response('secret-token from response', {
        status: 403,
        headers: { 'x-github-request-id': 'SAFE-REQUEST-ID' },
      }),
    );

  await assert.rejects(
    dispatchPagesDeployment(
      { token: 'secret-token', targetRepository: 'owner/publisher', artifactName: 'site' },
      context,
      { request },
    ),
    (error: unknown) => {
      assert.match(String(error), /status=403 request-id=SAFE-REQUEST-ID/u);
      assert.doesNotMatch(String(error), /secret-token/u);
      assert.doesNotMatch(String(error), /from response/u);
      return true;
    },
  );
});

void test('dispatch rejects malformed public inputs and derived context', async () => {
  const unusedRequest: Request = () => Promise.reject(new Error('request must not run'));
  await assert.rejects(
    dispatchPagesDeployment(
      { token: 'token', targetRepository: 'owner/repository/extra', artifactName: 'site' },
      context,
      { request: unusedRequest },
    ),
    /owner\/repository form/u,
  );
  await assert.rejects(
    dispatchPagesDeployment(
      { token: 'token', targetRepository: 'owner/repository', artifactName: '../site' },
      context,
      { request: unusedRequest },
    ),
    /artifact-name contains/u,
  );
  await assert.rejects(
    dispatchPagesDeployment(
      { token: 'token', targetRepository: 'owner/repository', artifactName: 'site' },
      { ...context, sourceRunId: 'not-a-run' },
      { request: unusedRequest },
    ),
    /workflow run ID/u,
  );
});
