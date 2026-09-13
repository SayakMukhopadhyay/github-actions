export interface ReleaseCommit {
  sha: string;
  subject: string;
}

export interface ReleaseFacts {
  schemaVersion: 1;
  repository: string;
  serverUrl: string;
  tagName: string;
  targetObject: string;
  targetCommit: string;
  previousTag: string | null;
  previousObject: string | null;
  commits: ReleaseCommit[];
  omittedCommitCount: number;
}

export interface GeneratedNotes {
  description: string;
  highlights: string[];
}

export interface ResponseClient {
  responses: { create(request: unknown): Promise<unknown> };
}

export interface WorkloadIdentityInputs {
  audience: string;
  identityProviderId: string;
  serviceAccountId: string;
}

export interface WorkloadIdentityClientOptions {
  apiKey: null;
  fetch?: typeof globalThis.fetch;
  workloadIdentity: {
    identityProviderId: string;
    serviceAccountId: string;
    provider: {
      tokenType: 'jwt';
      getToken: () => Promise<string>;
    };
  };
}

export type ClientFactory = (options: WorkloadIdentityClientOptions) => ResponseClient;
export type IDTokenProvider = (audience: string) => Promise<string>;
export interface GitHubOidcClaimDiagnostics {
  iss: string | null;
  aud: string | string[] | null;
  sub: string | null;
  repository: string | null;
  environment: string | null;
  job_workflow_ref: string | null;
  workflow_ref: string | null;
  ref: string | null;
  sha: string | null;
}
export type DiagnosticStage =
  'github-oidc-token' | 'openai-token-exchange' | 'openai-response-request' | 'openai-response-validation';
export type DiagnosticEvent =
  | { stage: 'github-oidc-token' | 'openai-response-validation'; event: 'started' | 'succeeded' }
  | { stage: 'github-oidc-token'; event: 'claims'; claims: GitHubOidcClaimDiagnostics }
  | { stage: 'openai-token-exchange' | 'openai-response-request'; event: 'started'; attempt: number }
  | {
      stage: 'openai-token-exchange' | 'openai-response-request';
      event: 'http-response';
      attempt: number;
      httpStatus: number;
    };
export type DiagnosticReporter = (diagnostic: DiagnosticEvent) => void;
export interface OpenAIDependencies {
  clientFactory?: ClientFactory;
  fetch?: typeof globalThis.fetch;
  getIDToken?: IDTokenProvider;
  reportDiagnostic?: DiagnosticReporter;
}

export type RequiredInputName =
  | 'openai-wif-audience'
  | 'openai-identity-provider-id'
  | 'openai-service-account-id'
  | 'context-file'
  | 'facts-file'
  | 'body-file';
export type InputFileRole = 'context-file' | 'facts-file' | 'body-file';
export type OperationFailureCategory = 'model-generation' | 'rendering' | 'output-write';
export type ModelGenerationFailureReason =
  'openai-client-initialization-failed' | 'openai-response-request-failed' | 'openai-response-validation-failed';
export type WorkloadIdentityFailureReason =
  'github-oidc-token-request-failed' | 'github-oidc-token-invalid' | 'openai-token-exchange-failed';

export type SafeFailureDiagnostic =
  | { category: 'input-validation'; reason: 'missing-required-input'; input: RequiredInputName }
  | { category: 'input-validation'; reason: 'missing-runner-temp' }
  | { category: 'input-file-validation'; reason: InputFileRole }
  | { category: 'release-facts-validation'; reason: 'invalid-facts' }
  | { category: 'workload-identity'; reason: WorkloadIdentityFailureReason }
  | { category: 'model-generation'; reason: ModelGenerationFailureReason | 'operation-failed' }
  | { category: Exclude<OperationFailureCategory, 'model-generation'>; reason: 'operation-failed' };

export class SafeActionFailure extends Error {
  readonly diagnostic: SafeFailureDiagnostic;

  constructor(diagnostic: SafeFailureDiagnostic) {
    super('create-release failed');
    this.name = 'SafeActionFailure';
    this.diagnostic = diagnostic;
  }
}

export function fail(diagnostic: SafeFailureDiagnostic): never {
  throw new SafeActionFailure(diagnostic);
}
