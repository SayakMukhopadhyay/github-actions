import { readFileSync, writeFileSync } from 'node:fs';
import { isMap, isScalar, parseDocument } from 'yaml';
import { requireRegularContainedFile } from '../../../check-version/check-version.ts';

function fail(message: string): never {
  throw new Error(message);
}

export function readChart(
  file: string,
  authorityRoot: string,
): { source: string; document: ReturnType<typeof parseDocument> } {
  const authorityFile = requireRegularContainedFile(authorityRoot, file, 'chart metadata');
  const source = readFileSync(authorityFile, 'utf8');
  const document = parseDocument(source, { keepSourceTokens: true, uniqueKeys: true });

  if (document.errors.length > 0 || !isMap(document.contents)) {
    fail(`${file} must contain a valid YAML mapping`);
  }

  return { source, document };
}

export function chartScalar(document: ReturnType<typeof parseDocument>, file: string, field: string): string {
  const node: unknown = document.get(field, true);

  if (!isScalar(node) || (typeof node.value !== 'string' && typeof node.value !== 'number')) {
    fail(`${file} must contain exactly one top-level ${field} field`);
  }

  return String(node.value);
}

export function patchChartScalars(
  file: string,
  authorityRoot: string,
  replacements: ReadonlyMap<string, string>,
): void {
  const authorityFile = requireRegularContainedFile(authorityRoot, file, 'chart metadata');
  const { source, document } = readChart(authorityFile, authorityRoot);
  const patches: { start: number; end: number; replacement: string }[] = [];

  for (const [field, value] of replacements) {
    const node: unknown = document.get(field, true);

    if (!isScalar(node) || node.range == null) {
      fail(`${file} must contain exactly one top-level ${field} field`);
    }

    const [start, end] = node.range;
    const original = source.slice(start, end);
    const quote =
      original.startsWith('"') && original.endsWith('"')
        ? '"'
        : original.startsWith("'") && original.endsWith("'")
          ? "'"
          : '';
    patches.push({ start, end, replacement: `${quote}${value}${quote}` });
  }

  let updated = source;

  for (const patch of patches.sort((left, right) => right.start - left.start)) {
    updated = `${updated.slice(0, patch.start)}${patch.replacement}${updated.slice(patch.end)}`;
  }

  const verified = parseDocument(updated, { uniqueKeys: true });

  if (verified.errors.length > 0) {
    fail(`could not update ${file}`);
  }

  for (const [field, value] of replacements) {
    if (chartScalar(verified, file, field) !== value) {
      fail(`could not update ${file} field ${field}`);
    }
  }

  writeFileSync(authorityFile, updated, 'utf8');
}
