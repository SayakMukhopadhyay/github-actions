import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';

interface ActionInput {
  default?: unknown;
  required?: unknown;
}

interface ActionMetadata {
  inputs?: Record<string, ActionInput>;
  outputs?: Record<string, unknown>;
}

function repositoryRoot(): string {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
}

function hasOwn(object: object, property: string): boolean {
  return Object.prototype.hasOwnProperty.call(object, property);
}

function callerRequired(input: ActionInput): boolean {
  return input.required === true && !hasOwn(input, 'default');
}

async function currentPublicActionNames(root: string): Promise<string[]> {
  const entries = await readdir(root, { withFileTypes: true });
  const names = await Promise.all(
    entries
      .filter((entry) => entry.isDirectory())
      .map(async (entry) => {
        try {
          await readFile(path.join(root, entry.name, 'action.yaml'), 'utf8');
          return entry.name;
        } catch (error: unknown) {
          if (isFileMissing(error)) {
            return undefined;
          }
          throw error;
        }
      }),
  );

  return names.filter((name): name is string => name !== undefined).sort();
}

function isFileMissing(error: unknown): error is NodeJS.ErrnoException {
  return typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT';
}

async function readCurrentMetadata(root: string, action: string): Promise<ActionMetadata> {
  return parse(await readFile(path.join(root, action, 'action.yaml'), 'utf8')) as ActionMetadata;
}

async function readBaselineMetadata(
  baselineDirectory: string,
  action: string,
): Promise<ActionMetadata> {
  return parse(
    await readFile(path.join(baselineDirectory, action, 'action.yaml'), 'utf8'),
  ) as ActionMetadata;
}

function compareInputs(
  action: string,
  baseline: ActionMetadata,
  current: ActionMetadata,
): string[] {
  const failures: string[] = [];
  const baselineInputs = baseline.inputs ?? {};
  const currentInputs = current.inputs ?? {};

  for (const [name, previous] of Object.entries(baselineInputs)) {
    const next = currentInputs[name];
    if (next === undefined) {
      failures.push(`${action}: input "${name}" was removed or renamed.`);
      continue;
    }
    if (!callerRequired(previous) && callerRequired(next)) {
      failures.push(`${action}: input "${name}" became caller-required.`);
    }
    if (hasOwn(previous, 'default')) {
      if (!hasOwn(next, 'default') || !Object.is(previous.default, next.default)) {
        failures.push(`${action}: input "${name}" default changed or was removed.`);
      }
    }
  }

  return failures;
}

function compareOutputs(
  action: string,
  baseline: ActionMetadata,
  current: ActionMetadata,
): string[] {
  const failures: string[] = [];
  const currentOutputs = current.outputs ?? {};
  for (const name of Object.keys(baseline.outputs ?? {})) {
    if (!hasOwn(currentOutputs, name)) {
      failures.push(`${action}: output "${name}" was removed or renamed.`);
    }
  }
  return failures;
}

export async function checkV1Compatibility(
  baselineDirectory: string,
  root = repositoryRoot(),
): Promise<void> {
  const [baselineNames, currentNames] = await Promise.all([
    currentPublicActionNames(baselineDirectory),
    currentPublicActionNames(root),
  ]);
  const currentNameSet = new Set(currentNames);
  const failures: string[] = [];

  for (const action of baselineNames) {
    if (!currentNameSet.has(action)) {
      failures.push(`${action}: public action was removed or renamed.`);
      continue;
    }
    const [baseline, current] = await Promise.all([
      readBaselineMetadata(baselineDirectory, action),
      readCurrentMetadata(root, action),
    ]);
    failures.push(...compareInputs(action, baseline, current));
    failures.push(...compareOutputs(action, baseline, current));
  }

  if (failures.length > 0) {
    throw new Error(
      `v1 compatibility check failed:\n${failures.map((failure) => `- ${failure}`).join('\n')}`,
    );
  }
}

function baselineDirectoryFromArguments(): string {
  const argument = process.argv[2];
  if (argument === undefined) {
    throw new Error(
      'Pass a directory containing action.yaml files extracted from the v1 tag, for example: node tooling/check-v1-compatibility.ts "$RUNNER_TEMP/v1-actions".',
    );
  }
  return path.resolve(argument);
}

if (
  process.argv[1] !== undefined &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  void checkV1Compatibility(baselineDirectoryFromArguments());
}
