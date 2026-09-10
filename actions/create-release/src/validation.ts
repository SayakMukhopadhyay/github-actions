import type { GeneratedNotes, ReleaseFacts } from './contracts.ts';

const MAX_RENDERED_COMMITS = 48;
const MAX_REPOSITORY_LENGTH = 256;
const MAX_SERVER_URL_LENGTH = 255;
const MAX_TAG_NAME_LENGTH = 255;
const unsafeGeneratedText =
  /https?:\/\/|www\.|\[[^\]]+\]\([^)]*\)|<[^>]+>|`|(^|[^\p{L}\p{N}_])v?\d+\.\d+\.\d+([^\p{L}\p{N}_]|$)|\b[0-9a-f]{7,64}\b|(^|\s)[\p{L}\p{N}_.-]+\/[\p{L}\p{N}_.:/-]+|(^|[^\p{L}\p{N}_])@[\p{L}\p{N}_]/iu;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function codePointLength(value: string): number {
  return [...value].length;
}

function isSafeLine(value: unknown, maximumLength: number): value is string {
  if (typeof value !== 'string' || value.length === 0 || codePointLength(value) > maximumLength) {
    return false;
  }

  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (codePoint === undefined || codePoint < 32 || codePoint === 127) {
      return false;
    }
  }

  return true;
}

function assertExactKeys(value: Record<string, unknown>, expected: string[]): void {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();

  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error('object contains unexpected fields');
  }
}

export function validateGeneratedNotes(value: unknown): GeneratedNotes {
  if (!isRecord(value)) {
    throw new Error('release notes must be an object');
  }

  assertExactKeys(value, ['description', 'highlights']);

  if (!isSafeLine(value.description, 1_200)) {
    throw new Error('release description is invalid');
  }

  if (!Array.isArray(value.highlights) || value.highlights.length < 1 || value.highlights.length > 6) {
    throw new Error('release highlights are invalid');
  }

  if (!value.highlights.every((highlight) => isSafeLine(highlight, 240))) {
    throw new Error('release highlight is invalid');
  }

  if (unsafeGeneratedText.test([value.description, ...value.highlights].join('\n'))) {
    throw new Error('release notes contain disallowed non-descriptive content');
  }

  return { description: value.description, highlights: value.highlights };
}

export function validateReleaseFacts(value: unknown): ReleaseFacts {
  if (!isRecord(value)) {
    throw new Error('release facts must be an object');
  }

  assertExactKeys(value, [
    'schemaVersion',
    'repository',
    'serverUrl',
    'tagName',
    'targetObject',
    'targetCommit',
    'previousTag',
    'previousObject',
    'commits',
    'omittedCommitCount',
  ]);

  if (value.schemaVersion !== 1) {
    throw new Error('unsupported release facts version');
  }

  if (
    typeof value.repository !== 'string' ||
    codePointLength(value.repository) > MAX_REPOSITORY_LENGTH ||
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(value.repository)
  ) {
    throw new Error('invalid repository in release facts');
  }

  if (
    typeof value.serverUrl !== 'string' ||
    codePointLength(value.serverUrl) > MAX_SERVER_URL_LENGTH ||
    !/^https:\/\/[A-Za-z0-9.-]+(?::\d+)?$/.test(value.serverUrl)
  ) {
    throw new Error('invalid server URL in release facts');
  }

  if (
    typeof value.tagName !== 'string' ||
    value.tagName.length === 0 ||
    codePointLength(value.tagName) > MAX_TAG_NAME_LENGTH ||
    /[\r\n]/u.test(value.tagName)
  ) {
    throw new Error('invalid tag in release facts');
  }

  if (typeof value.targetObject !== 'string' || !/^[0-9a-f]{40,64}$/iu.test(value.targetObject)) {
    throw new Error('invalid tag object in release facts');
  }

  if (typeof value.targetCommit !== 'string' || !/^[0-9a-f]{40,64}$/iu.test(value.targetCommit)) {
    throw new Error('invalid target commit in release facts');
  }

  if (
    value.previousTag !== null &&
    (typeof value.previousTag !== 'string' ||
      value.previousTag.length === 0 ||
      codePointLength(value.previousTag) > MAX_TAG_NAME_LENGTH ||
      /[\r\n]/u.test(value.previousTag))
  ) {
    throw new Error('invalid previous tag in release facts');
  }

  if (
    (value.previousTag === null && value.previousObject !== null) ||
    (value.previousTag !== null &&
      (typeof value.previousObject !== 'string' || !/^[0-9a-f]{40,64}$/iu.test(value.previousObject)))
  ) {
    throw new Error('invalid previous tag object in release facts');
  }

  if (
    typeof value.omittedCommitCount !== 'number' ||
    !Number.isSafeInteger(value.omittedCommitCount) ||
    value.omittedCommitCount < 0
  ) {
    throw new Error('invalid omitted commit count in release facts');
  }

  if (!Array.isArray(value.commits) || value.commits.length > MAX_RENDERED_COMMITS) {
    throw new Error('invalid commit list in release facts');
  }

  const commits = value.commits.map((candidate) => {
    if (!isRecord(candidate)) {
      throw new Error('invalid commit entry in release facts');
    }

    assertExactKeys(candidate, ['sha', 'subject']);

    if (typeof candidate.sha !== 'string' || !/^[0-9a-f]{40,64}$/iu.test(candidate.sha)) {
      throw new Error('invalid commit ID in release facts');
    }

    if (!isSafeLine(candidate.subject, 240)) {
      throw new Error('invalid commit subject in release facts');
    }

    return { sha: candidate.sha, subject: candidate.subject };
  });

  return {
    schemaVersion: 1,
    repository: value.repository,
    serverUrl: value.serverUrl,
    tagName: value.tagName,
    targetObject: value.targetObject,
    targetCommit: value.targetCommit,
    previousTag: value.previousTag,
    previousObject: value.previousObject as string | null,
    commits,
    omittedCommitCount: value.omittedCommitCount,
  };
}
