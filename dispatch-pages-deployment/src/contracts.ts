export const EVENT_TYPE = 'deploy-pages' as const;

export interface DispatchInputs {
  token: string;
  targetRepository: string;
  artifactName: string;
}

export interface GitHubContext {
  apiUrl: string;
  sourceRepository: string;
  sourceRunId: string;
  sourceSha: string;
}

export interface DispatchPayload {
  event_type: typeof EVENT_TYPE;
  client_payload: { source_repository: string; source_run_id: string; source_sha: string; artifact_name: string };
}

export type Request = (url: string, init: RequestInit) => Promise<Response>;
export type Sleep = (milliseconds: number) => Promise<void>;

export interface DispatchDependencies {
  request?: Request;
  sleep?: Sleep;
}
