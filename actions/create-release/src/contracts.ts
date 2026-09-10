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

export type ClientFactory = (apiKey: string) => ResponseClient;
export type RequiredInputName = 'openai-api-key' | 'context-file' | 'facts-file' | 'body-file';
export type InputFileRole = 'context-file' | 'facts-file' | 'body-file';
export type OperationFailureCategory = 'model-generation' | 'rendering' | 'output-write';

export type SafeFailureDiagnostic =
  | { category: 'input-validation'; reason: 'missing-required-input'; input: RequiredInputName }
  | { category: 'input-validation'; reason: 'missing-runner-temp' }
  | { category: 'input-file-validation'; reason: InputFileRole }
  | { category: 'release-facts-validation'; reason: 'invalid-facts' }
  | { category: OperationFailureCategory; reason: 'operation-failed' };

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
