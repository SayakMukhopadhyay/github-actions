import type { GitHubContext } from './contracts.ts';

const MAX_REPOSITORY_LENGTH = 256;
const MAX_ARTIFACT_NAME_LENGTH = 255;

function fail(message: string): never {
  throw new Error(message);
}

export function validateRepository(repository: string, label: string): string {
  if (
    repository.length === 0 ||
    repository.length > MAX_REPOSITORY_LENGTH ||
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u.test(repository)
  ) {
    fail(`${label} must use owner/repository form with only letters, numbers, dots, underscores, and hyphens`);
  }

  const [owner, name] = repository.split('/');

  if (owner === '.' || owner === '..' || name === '.' || name === '..') {
    fail(`${label} contains an invalid owner or repository name`);
  }

  return repository;
}

export function validateArtifactName(artifactName: string): string {
  if (artifactName.length === 0 || artifactName.length > MAX_ARTIFACT_NAME_LENGTH) {
    fail(`artifact-name must contain between 1 and ${MAX_ARTIFACT_NAME_LENGTH} characters`);
  }

  const forbiddenCharacters = new Set(['"', '*', ':', '<', '>', '?', '\\', '/', '|']);

  for (const character of artifactName) {
    const codePoint = character.codePointAt(0);

    if (codePoint === undefined || codePoint <= 31 || codePoint === 127 || forbiddenCharacters.has(character)) {
      fail('artifact-name contains a control character or a character rejected by GitHub artifacts');
    }
  }

  return artifactName;
}

export function validateContext(context: GitHubContext): GitHubContext {
  validateRepository(context.sourceRepository, 'source repository');

  if (!/^[1-9][0-9]*$/u.test(context.sourceRunId)) {
    fail('source workflow run ID is unavailable or invalid');
  }
  if (!/^[0-9a-f]{40}$/iu.test(context.sourceSha)) {
    fail('source commit SHA is unavailable or invalid');
  }

  let apiUrl: URL;

  try {
    apiUrl = new URL(context.apiUrl);
  } catch {
    fail('GitHub API URL is invalid');
  }
  if (
    apiUrl.protocol !== 'https:' ||
    apiUrl.username !== '' ||
    apiUrl.password !== '' ||
    apiUrl.search !== '' ||
    apiUrl.hash !== ''
  ) {
    fail('GitHub API URL must be an HTTPS URL without credentials, a query, or a fragment');
  }

  return context;
}
