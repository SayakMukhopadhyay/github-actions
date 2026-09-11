import { writeFile, realpath } from 'node:fs/promises';
import { basename, dirname, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import {
  fail,
  SafeActionFailure,
  type ClientFactory,
  type OperationFailureCategory,
  type RequiredInputName,
  type ReleaseFacts,
  type SafeFailureDiagnostic,
} from './contracts.ts';
import { readInputFile, validateInputFile } from './files.ts';
import { generateNotes } from './openai.ts';
import { renderReleaseBody } from './render.ts';
import { validateReleaseFacts } from './validation.ts';

export * from './contracts.ts';
export * from './files.ts';
export * from './openai.ts';
export * from './render.ts';
export * from './validation.ts';

const MAX_CONTEXT_BYTES = 60_000;
const MAX_FACTS_BYTES = 512_000;
const MAX_BODY_BYTES = 120_000;

function getActionInput(name: RequiredInputName): string {
  const value = process.env[`INPUT_${name.replaceAll(' ', '_').toUpperCase()}`]?.trim() ?? '';

  if (value === '') {
    fail({ category: 'input-validation', reason: 'missing-required-input', input: name });
  }

  return value;
}

function formatFailure(error: unknown, fallbackCategory: OperationFailureCategory): string {
  const diagnostic: SafeFailureDiagnostic =
    error instanceof SafeActionFailure ? error.diagnostic : { category: fallbackCategory, reason: 'operation-failed' };

  return `create-release: failed: category=${diagnostic.category} reason=${diagnostic.reason}${'input' in diagnostic ? ` input=${diagnostic.input}` : ''}\n`;
}

export async function run(clientFactory?: ClientFactory): Promise<void> {
  let failureCategory: OperationFailureCategory = 'model-generation';

  try {
    const apiKey = getActionInput('openai-api-key');
    const contextInput = getActionInput('context-file');
    const factsInput = getActionInput('facts-file');
    const bodyInput = getActionInput('body-file');
    const runnerTemp = process.env.RUNNER_TEMP;

    if (!runnerTemp) {
      fail({ category: 'input-validation', reason: 'missing-runner-temp' });
    }

    const contextPath = await validateInputFile('context-file', contextInput, runnerTemp, MAX_CONTEXT_BYTES);
    const factsPath = await validateInputFile('facts-file', factsInput, runnerTemp, MAX_FACTS_BYTES);

    let bodyPath: string;

    try {
      const canonicalRunnerTemp = await realpath(runnerTemp);
      const requestedBodyPath = resolve(bodyInput);
      const canonicalBodyDirectory = await realpath(dirname(requestedBodyPath));
      bodyPath = resolve(canonicalBodyDirectory, basename(requestedBodyPath));
      const bodyFromRunnerTemp = relative(canonicalRunnerTemp, bodyPath);
      if (
        bodyFromRunnerTemp === '' ||
        bodyFromRunnerTemp.startsWith('..') ||
        canonicalBodyDirectory !== dirname(factsPath)
      ) {
        fail({ category: 'input-file-validation', reason: 'body-file' });
      }
    } catch (error) {
      if (error instanceof SafeActionFailure) {
        throw error;
      }
      fail({ category: 'input-file-validation', reason: 'body-file' });
    }

    const context = await readInputFile('context-file', contextPath);
    const factsText = await readInputFile('facts-file', factsPath);

    let facts: ReleaseFacts;

    try {
      facts = validateReleaseFacts(JSON.parse(factsText));
    } catch {
      fail({ category: 'release-facts-validation', reason: 'invalid-facts' });
    }

    const notes = await generateNotes(context, apiKey, clientFactory);

    failureCategory = 'rendering';
    const body = renderReleaseBody(notes, facts);

    if (Buffer.byteLength(body, 'utf8') > MAX_BODY_BYTES) {
      throw new Error('rendered release body exceeds the maximum size');
    }

    failureCategory = 'output-write';
    await writeFile(bodyPath, body, { encoding: 'utf8', flag: 'wx', mode: 0o600 });
  } catch (error) {
    process.stderr.write(formatFailure(error, failureCategory));
    process.exitCode = 1;
  }
}

const executedPath = process.argv[1] === undefined ? undefined : pathToFileURL(resolve(process.argv[1])).href;
if (executedPath === import.meta.url) {
  await run();
}
