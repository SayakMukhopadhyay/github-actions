import { lstat, readFile, realpath } from 'node:fs/promises';
import { relative, resolve } from 'node:path';
import { fail, type InputFileRole } from './contracts.ts';

async function checkedInputFile(path: string, runnerTemp: string, maximumBytes: number): Promise<string> {
  const inputStats = await lstat(path);

  if (!inputStats.isFile() || inputStats.isSymbolicLink()) {
    throw new Error('release handoff file must be a regular non-symbolic file');
  }

  const canonicalRunnerTemp = await realpath(runnerTemp);
  const canonicalPath = await realpath(path);
  const pathFromRunnerTemp = relative(canonicalRunnerTemp, canonicalPath);

  if (
    pathFromRunnerTemp === '' ||
    pathFromRunnerTemp.startsWith('..') ||
    resolve(canonicalRunnerTemp, pathFromRunnerTemp) !== canonicalPath
  ) {
    throw new Error('release handoff file is outside RUNNER_TEMP');
  }

  if (inputStats.size > maximumBytes) {
    throw new Error('release handoff file is invalid or too large');
  }

  return canonicalPath;
}

export async function validateInputFile(
  role: InputFileRole,
  path: string,
  runnerTemp: string,
  maximumBytes: number,
): Promise<string> {
  try {
    return await checkedInputFile(path, runnerTemp, maximumBytes);
  } catch {
    fail({ category: 'input-file-validation', reason: role });
  }
}

export async function readInputFile(role: InputFileRole, path: string): Promise<string> {
  try {
    return await readFile(path, 'utf8');
  } catch {
    fail({ category: 'input-file-validation', reason: role });
  }
}
