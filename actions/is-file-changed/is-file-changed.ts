import * as core from '@actions/core';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

function fail(message: string): never {
  throw new Error(message);
}

export function parseChangedPaths(contents: Buffer): string[] {
  const records = contents.toString('utf8').split('\0');
  if (records.at(-1) === '') {
    records.pop();
  }

  const paths: string[] = [];
  for (let index = 0; index < records.length;) {
    const status = records[index++];
    if (status === undefined || status.length === 0) {
      fail('truncated Git name-status record');
    }
    if (status.startsWith('R') || status.startsWith('C')) {
      const oldPath = records[index++];
      const newPath = records[index++];
      if (oldPath === undefined || newPath === undefined) {
        fail('truncated Git rename/copy record');
      }
      paths.push(oldPath, newPath);
    } else {
      const path = records[index++];
      if (path === undefined) {
        fail('truncated Git name-status record');
      }
      paths.push(path);
    }
  }

  return paths;
}

export function matchChangedFiles(pattern: string, changedFiles: string): boolean {
  if (pattern.length === 0) {
    fail('pattern is required');
  }

  let expression: RegExp;
  try {
    expression = new RegExp(pattern);
  } catch {
    fail(`invalid JavaScript regular expression: ${pattern}`);
  }

  return parseChangedPaths(readFileSync(changedFiles)).some((path) => expression.test(path));
}

export function run(): void {
  try {
    core.setOutput(
      'changed',
      matchChangedFiles(
        core.getInput('pattern', { required: true, trimWhitespace: false }),
        core.getInput('changed-files', { required: true }),
      ),
    );
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : 'Unknown error occurred');
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run();
}
