import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  extractGitHubOidcClaimDiagnostics,
  formatDiagnostic,
  SafeActionFailure,
  type GitHubOidcClaimDiagnostics,
} from '../actions/create-release/src/index.ts';

function createJwt(payload: unknown): string {
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
  const encodedPayload = Buffer.from(JSON.stringify(payload)).toString('base64url');
  return `${header}.${encodedPayload}.signature-secret`;
}

const completeClaims: GitHubOidcClaimDiagnostics = {
  iss: 'https://token.actions.githubusercontent.com',
  aud: 'https://api.openai.com/v1',
  sub: 'repo:kode-blox/golfs:environment:production',
  repository: 'kode-blox/golfs',
  environment: 'production',
  job_workflow_ref: 'kode-blox/golfs/.github/workflows/release.yaml@refs/heads/main',
  workflow_ref: 'kode-blox/golfs/.github/workflows/release.yaml@refs/heads/main',
  ref: 'refs/heads/main',
  sha: 'a'.repeat(40),
};

void test('extracts only the strict allowlist from a valid GitHub OIDC payload', () => {
  const token = createJwt({
    ...completeClaims,
    actor: 'untrusted-actor-secret',
    authorization: 'Bearer untrusted-authorization-secret',
  });

  assert.deepEqual(extractGitHubOidcClaimDiagnostics(token), completeClaims);
});

void test('represents every missing allowlisted claim explicitly', () => {
  assert.deepEqual(extractGitHubOidcClaimDiagnostics(createJwt({ arbitrary: 'untrusted-secret' })), {
    iss: null,
    aud: null,
    sub: null,
    repository: null,
    environment: null,
    job_workflow_ref: null,
    workflow_ref: null,
    ref: null,
    sha: null,
  });
});

void test('preserves an array audience without admitting other value types', () => {
  assert.deepEqual(
    extractGitHubOidcClaimDiagnostics(
      createJwt({ ...completeClaims, aud: ['https://api.openai.com/v1', 'secondary-audience'] }),
    ).aud,
    ['https://api.openai.com/v1', 'secondary-audience'],
  );
});

void test('malformed JWTs, payloads, and allowlisted claim types fail closed', () => {
  const malformedTokens = [
    'not-a-jwt',
    `a.${Buffer.from('{}').toString('base64url')}.signature`,
    'header.%.signature',
    `header.${Buffer.from('not-json').toString('base64url')}.signature`,
    createJwt([]),
    createJwt({ ...completeClaims, aud: ['valid', { unsafe: 'untrusted-secret' }] }),
    createJwt({ ...completeClaims, repository: { unsafe: 'untrusted-secret' } }),
  ];

  for (const token of malformedTokens) {
    assert.throws(
      () => extractGitHubOidcClaimDiagnostics(token),
      (error) => {
        assert.ok(error instanceof SafeActionFailure);
        assert.deepEqual(error.diagnostic, {
          category: 'workload-identity',
          reason: 'github-oidc-token-invalid',
        });
        assert.doesNotMatch(error.message, /untrusted|signature/u);
        return true;
      },
    );
  }
});

void test('formats claims in a fixed escaped order without leaking the JWT or arbitrary claims', () => {
  const token = createJwt({
    ...completeClaims,
    repository: 'kode-blox/golfs\n::warning::injected',
    arbitrary: 'untrusted-arbitrary-secret',
  });
  const diagnostic = formatDiagnostic({
    stage: 'github-oidc-token',
    event: 'claims',
    claims: extractGitHubOidcClaimDiagnostics(token),
  });

  assert.equal(
    diagnostic,
    'create-release: diagnostic stage=github-oidc-token event=claims iss="https://token.actions.githubusercontent.com" aud="https://api.openai.com/v1" sub="repo:kode-blox/golfs:environment:production" repository="kode-blox/golfs\\n::warning::injected" environment="production" job_workflow_ref="kode-blox/golfs/.github/workflows/release.yaml@refs/heads/main" workflow_ref="kode-blox/golfs/.github/workflows/release.yaml@refs/heads/main" ref="refs/heads/main" sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"',
  );
  assert.doesNotMatch(diagnostic, /signature-secret|untrusted-arbitrary-secret/u);
  assert.ok(!diagnostic.includes(token));
  assert.equal(diagnostic.split('\n').length, 1);
});

void test('formats absent claims and array audiences explicitly', () => {
  const claims = extractGitHubOidcClaimDiagnostics(createJwt({ aud: ['primary', 'secondary'] }));
  const diagnostic = formatDiagnostic({ stage: 'github-oidc-token', event: 'claims', claims });

  assert.equal(
    diagnostic,
    'create-release: diagnostic stage=github-oidc-token event=claims iss=<absent> aud=["primary","secondary"] sub=<absent> repository=<absent> environment=<absent> job_workflow_ref=<absent> workflow_ref=<absent> ref=<absent> sha=<absent>',
  );
});
