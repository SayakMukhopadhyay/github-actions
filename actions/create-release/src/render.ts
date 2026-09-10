import type { GeneratedNotes, ReleaseFacts } from './contracts.ts';

function markdownEscape(value: string): string {
  return value
    .replaceAll('\r', ' ')
    .replaceAll('\n', ' ')
    .replace(/[&@\\`*_[\]()#!<>|]/gu, (character) =>
      character === '&' ? '&amp;' : character === '@' ? '&#64;' : `\\${character}`,
    );
}
export function renderReleaseBody(notes: GeneratedNotes, facts: ReleaseFacts): string {
  const lines = [markdownEscape(notes.description), '', '## Highlights', ''];

  for (const highlight of notes.highlights) {
    lines.push(`- ${markdownEscape(highlight)}`);
  }

  lines.push('', '## Commits', '');

  if (facts.omittedCommitCount > 0) {
    lines.push(`_${facts.omittedCommitCount} earlier mainline commits omitted for length._`, '');
  }

  if (facts.commits.length === 0) {
    lines.push('_No mainline commits are present in this tag range._');
  } else {
    for (const commit of facts.commits) {
      lines.push(
        `- [\`${commit.sha.slice(0, 7)}\`](${facts.serverUrl}/${facts.repository}/commit/${commit.sha}) ${markdownEscape(commit.subject)}`,
      );
    }
  }

  lines.push('', '## Full changelog', '');

  const encodedTag = encodeURIComponent(facts.tagName);

  if (facts.previousTag === null) {
    lines.push(
      `[View the initial release source at ${markdownEscape(facts.tagName)}](${facts.serverUrl}/${facts.repository}/tree/${encodedTag})`,
    );
  } else {
    lines.push(
      `[Compare ${markdownEscape(facts.previousTag)}...${markdownEscape(facts.tagName)}](${facts.serverUrl}/${facts.repository}/compare/${encodeURIComponent(facts.previousTag)}...${encodedTag})`,
    );
  }

  return `${lines.join('\n')}\n`;
}
