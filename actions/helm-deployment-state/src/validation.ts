import { existsSync, lstatSync, readFileSync } from 'node:fs';
import { isAbsolute, relative } from 'node:path';
import { isMap, isScalar, parseDocument } from 'yaml';

const CANONICAL_VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const DEVELOPMENT_VERSION = /^0\.0\.0-build-([0-9a-f]{40})$/u;

function fail(message: string): never {
  throw new Error(message);
}

export function ensureContained(parent: string, child: string, label: string): void {
  const relativeChild = relative(parent, child);

  if (
    relativeChild === '..' ||
    relativeChild.startsWith(`..${process.platform === 'win32' ? '\\' : '/'}`) ||
    isAbsolute(relativeChild)
  ) {
    fail(`${label} escapes the checkout`);
  }
}

export function requiredInput(value: string, label: string): string {
  if (value.trim().length === 0 || value.includes('\0') || value.includes('\n') || value.includes('\r')) {
    fail(`${label} must be a non-empty single-line value`);
  }

  return value;
}

export function parseMapping(file: string): ReturnType<typeof parseDocument> {
  if (!existsSync(file)) {
    fail(`authority file does not exist: ${file}`);
  }

  const status = lstatSync(file);

  if (status.isSymbolicLink()) {
    fail(`authority file must not be a symbolic link: ${file}`);
  }
  if (!status.isFile()) {
    fail(`authority path must be a regular file: ${file}`);
  }

  const document = parseDocument(readFileSync(file, 'utf8'), { uniqueKeys: true });

  if (document.errors.length > 0 || !isMap(document.contents)) {
    fail(`${file} must contain a valid YAML mapping`);
  }

  return document;
}

export function scalarValue(node: unknown, label: string): string {
  if (!isScalar(node) || !['string', 'number', 'boolean', 'bigint'].includes(typeof node.value)) {
    fail(`${label} must be a non-empty single-line scalar`);
  }

  const value = String(node.value);

  if (value.trim().length === 0 || value.includes('\0') || value.includes('\n') || value.includes('\r')) {
    fail(`${label} must be a non-empty single-line scalar`);
  }

  return value;
}

export function optionalStringScalar(node: unknown, label: string): string | undefined {
  if (node === undefined || node === null) {
    return undefined;
  }

  if (!isScalar(node) || typeof node.value !== 'string') {
    fail(`${label} must be a non-empty single-line string scalar`);
  }

  return scalarValue(node, label);
}

export function sourceRef(version: string): string {
  const development = DEVELOPMENT_VERSION.exec(version);

  if (development !== null) {
    return development[1] ?? fail('development chart version did not contain a commit SHA');
  }
  if (CANONICAL_VERSION.test(version)) {
    return `chart-v${version}`;
  }

  return fail(`dependency version '${version}' is not a supported development or stable chart version`);
}
