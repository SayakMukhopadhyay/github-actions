export type Increment = 'patch' | 'minor' | 'major';

export interface MutateVersionsOptions {
  workspace: string;
  workingDirectory: string;
  increment: string;
  helm: boolean;
  go: boolean;
}

export interface MutationResult {
  applicationVersion: string;
  chartVersion: string;
}
