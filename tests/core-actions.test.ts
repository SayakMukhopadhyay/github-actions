import assert from 'node:assert/strict';
import {
  mkdtempSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, test, type TestContext } from 'node:test';
import * as ts from 'typescript';
import { incrementVersion, mutateVersions } from '../actions/bump-version/bump-version.ts';
import {
  matchChangedFiles,
  parseChangedPaths,
} from '../actions/is-file-changed/is-file-changed.ts';
import { checkVersion, readCanonicalVersion } from '../check-version/check-version.ts';

const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

function temporaryDirectory(): string {
  const directory = mkdtempSync(join(tmpdir(), 'github-actions-core-'));
  temporaryDirectories.push(directory);
  return directory;
}

function writeChart(
  repository: string,
  applicationVersion = '1.2.3',
  chartVersion = '0.4.0',
): void {
  mkdirSync(join(repository, 'charts'), { recursive: true });
  writeFileSync(join(repository, 'VERSION'), `${applicationVersion}\n`);
  writeFileSync(join(repository, 'charts', 'VERSION'), `${chartVersion}\n`);
  writeFileSync(
    join(repository, 'charts', 'Chart.yaml'),
    `apiVersion: v2\nname: fixture\n# preserve this comment\nversion: ${chartVersion} # chart\nappVersion: "${applicationVersion}"\n`,
  );
}

function writeChangedFiles(...records: string[]): string {
  const file = join(temporaryDirectory(), 'changed-files');
  writeFileSync(file, Buffer.from(`${records.join('\0')}\0`, 'utf8'));
  return file;
}

function createFileSymlinkOrSkip(context: TestContext, target: string, path: string): boolean {
  try {
    symlinkSync(target, path, 'file');
    return true;
  } catch (error) {
    const code = error instanceof Error && 'code' in error ? error.code : undefined;
    if (code === 'EPERM' || code === 'EACCES' || code === 'ENOTSUP') {
      context.skip(`file symlinks are unavailable on this platform (${String(code)})`);
      return false;
    }
    throw error;
  }
}

function collectTypeScriptFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      return entry.name === 'dist' || entry.name === 'node_modules'
        ? []
        : collectTypeScriptFiles(path);
    }
    return entry.isFile() && entry.name.endsWith('.ts') ? [path] : [];
  });
}

function importedModule(node: ts.Node): string | undefined {
  if (ts.isImportDeclaration(node) && ts.isStringLiteral(node.moduleSpecifier)) {
    return node.moduleSpecifier.text;
  }
  if (
    ts.isImportEqualsDeclaration(node) &&
    ts.isExternalModuleReference(node.moduleReference) &&
    node.moduleReference.expression !== undefined &&
    ts.isStringLiteral(node.moduleReference.expression)
  ) {
    return node.moduleReference.expression.text;
  }
  if (
    ts.isCallExpression(node) &&
    node.arguments.length === 1 &&
    ts.isStringLiteral(node.arguments[0]) &&
    (node.expression.kind === ts.SyntaxKind.ImportKeyword ||
      (ts.isIdentifier(node.expression) && node.expression.text === 'require'))
  ) {
    return node.arguments[0].text;
  }
  return undefined;
}

void test('TypeScript sources never import command-execution modules', () => {
  const repositoryRoot = join(import.meta.dirname, '..');
  const forbiddenModules = new Set(['node:child_process', 'child_process']);
  const sourceRoots = ['check-version', 'actions', 'tooling', 'tests'];
  const violations: string[] = [];

  for (const sourceRoot of sourceRoots) {
    for (const file of collectTypeScriptFiles(join(repositoryRoot, sourceRoot))) {
      const source = ts.createSourceFile(
        file,
        readFileSync(file, 'utf8'),
        ts.ScriptTarget.Latest,
        true,
        ts.ScriptKind.TS,
      );
      const visit = (node: ts.Node): void => {
        const moduleName = importedModule(node);
        if (moduleName !== undefined && forbiddenModules.has(moduleName)) {
          violations.push(`${file}: imports ${moduleName}`);
        }
        ts.forEachChild(node, visit);
      };
      visit(source);
    }
  }

  assert.deepEqual(violations, []);
});

void test('check-version validates canonical application and Helm authorities', () => {
  const repository = temporaryDirectory();
  writeChart(repository);

  checkVersion({ workspace: repository, workingDirectory: '.', helm: true });
  checkVersion({ workspace: repository, workingDirectory: '.', helm: false });
});

void test('check-version rejects noncanonical, multiline, escaping, and mismatched metadata', () => {
  const root = temporaryDirectory();
  const repository = join(root, 'repository');
  mkdirSync(repository);
  writeFileSync(join(repository, 'VERSION'), '1.2.3-rc.1\n');
  assert.throws(
    () => readCanonicalVersion(join(repository, 'VERSION'), 'application version'),
    /canonical MAJOR\.MINOR\.PATCH/,
  );

  writeFileSync(join(repository, 'VERSION'), '1.2.3\n\n');
  assert.throws(
    () => readCanonicalVersion(join(repository, 'VERSION'), 'application version'),
    /exactly one line/,
  );
  assert.throws(
    () => checkVersion({ workspace: repository, workingDirectory: '..', helm: false }),
    /escapes the checkout/,
  );

  writeChart(repository);
  writeFileSync(
    join(repository, 'charts', 'Chart.yaml'),
    'apiVersion: v2\nname: fixture\nversion: 0.4.0\nappVersion: "9.9.9"\n',
  );
  assert.throws(
    () => checkVersion({ workspace: repository, workingDirectory: '.', helm: true }),
    /appVersion mismatch.*expected '1\.2\.3', got '9\.9\.9'/,
  );
});

void test('check-version rejects authority files that are symlinks', (context) => {
  const root = temporaryDirectory();
  const repository = join(root, 'repository');
  const externalVersion = join(root, 'external-version');
  mkdirSync(repository);
  writeFileSync(externalVersion, '1.2.3\n');
  if (!createFileSymlinkOrSkip(context, externalVersion, join(repository, 'VERSION'))) {
    return;
  }

  assert.throws(
    () => checkVersion({ workspace: repository, workingDirectory: '.', helm: false }),
    /regular non-symlink file/,
  );
});

void test('version increments are canonical and do not lose integer precision', () => {
  assert.equal(incrementVersion('1.2.3', 'patch'), '1.2.4');
  assert.equal(incrementVersion('1.2.3', 'minor'), '1.3.0');
  assert.equal(incrementVersion('1.2.3', 'major'), '2.0.0');
  assert.equal(incrementVersion('9007199254740993.0.0', 'major'), '9007199254740994.0.0');
  assert.throws(
    () => incrementVersion('1.2.3', 'prerelease'),
    /increment must be patch, minor, or major/,
  );
});

void test('bump-version mutates only selected authorities while preserving Chart.yaml formatting', () => {
  const repository = temporaryDirectory();
  writeChart(repository);

  const result = mutateVersions({
    workspace: repository,
    workingDirectory: '.',
    increment: 'patch',
    helm: true,
    go: true,
  });
  assert.deepEqual(result, { applicationVersion: '1.2.4', chartVersion: '0.4.1' });
  assert.equal(readFileSync(join(repository, 'VERSION'), 'utf8'), '1.2.4\n');
  assert.equal(readFileSync(join(repository, 'charts', 'VERSION'), 'utf8'), '0.4.1\n');
  assert.equal(
    readFileSync(join(repository, 'charts', 'Chart.yaml'), 'utf8'),
    'apiVersion: v2\nname: fixture\n# preserve this comment\nversion: 0.4.1 # chart\nappVersion: "1.2.4"\n',
  );
});

void test('bump-version preserves Helm-only, Go-only, and no-target behavior', () => {
  const helmOnly = temporaryDirectory();
  writeChart(helmOnly);
  assert.deepEqual(
    mutateVersions({
      workspace: helmOnly,
      workingDirectory: '.',
      increment: 'minor',
      helm: true,
      go: false,
    }),
    {
      applicationVersion: '',
      chartVersion: '0.5.0',
    },
  );
  assert.equal(readFileSync(join(helmOnly, 'VERSION'), 'utf8'), '1.2.3\n');
  assert.match(
    readFileSync(join(helmOnly, 'charts', 'Chart.yaml'), 'utf8'),
    /appVersion: "1\.2\.3"/,
  );

  const goOnly = temporaryDirectory();
  writeChart(goOnly);
  assert.deepEqual(
    mutateVersions({
      workspace: goOnly,
      workingDirectory: '.',
      increment: 'major',
      helm: false,
      go: true,
    }),
    {
      applicationVersion: '2.0.0',
      chartVersion: '',
    },
  );
  assert.equal(readFileSync(join(goOnly, 'charts', 'VERSION'), 'utf8'), '0.4.0\n');
  assert.deepEqual(
    mutateVersions({
      workspace: join(temporaryDirectory(), 'missing'),
      workingDirectory: '.',
      increment: 'invalid',
      helm: false,
      go: false,
    }),
    { applicationVersion: '', chartVersion: '' },
  );
});

void test('bump-version does not write through a symlinked authority file', (context) => {
  const root = temporaryDirectory();
  const repository = join(root, 'repository');
  const externalVersion = join(root, 'external-version');
  writeChart(repository);
  writeFileSync(externalVersion, '1.2.3\n');
  rmSync(join(repository, 'VERSION'));
  if (!createFileSymlinkOrSkip(context, externalVersion, join(repository, 'VERSION'))) {
    return;
  }

  assert.throws(
    () =>
      mutateVersions({
        workspace: repository,
        workingDirectory: '.',
        increment: 'patch',
        helm: false,
        go: true,
      }),
    /regular non-symlink file/,
  );
  assert.equal(readFileSync(externalVersion, 'utf8'), '1.2.3\n');
});

void test('is-file-changed parses ordinary, rename, and copy records', () => {
  const contents = Buffer.from(
    'M\0VERSION\0R100\0old name.txt\0new name.txt\0C100\0source.txt\0copy.txt\0',
    'utf8',
  );
  assert.deepEqual(parseChangedPaths(contents), [
    'VERSION',
    'old name.txt',
    'new name.txt',
    'source.txt',
    'copy.txt',
  ]);
  assert.throws(
    () => parseChangedPaths(Buffer.from('R100\0old.txt\0', 'utf8')),
    /truncated Git rename\/copy record/,
  );
});

void test('is-file-changed uses JavaScript RegExp against every changed path', () => {
  const changedFiles = writeChangedFiles(
    'M',
    'VERSION',
    'R100',
    'old name.txt',
    'new name;$(safe).txt',
    'D',
    'deleted.txt',
  );
  assert.equal(matchChangedFiles('^VERSION$', changedFiles), true);
  assert.equal(matchChangedFiles('^old name\\.txt$', changedFiles), true);
  assert.equal(matchChangedFiles('^new name;\\$\\(safe\\)\\.txt$', changedFiles), true);
  assert.equal(matchChangedFiles('^deleted\\.txt$', changedFiles), true);
  assert.equal(matchChangedFiles('^charts/', changedFiles), false);
  assert.equal(matchChangedFiles('(?<=new )name', changedFiles), true);
  assert.throws(
    () => matchChangedFiles('[', changedFiles),
    /invalid JavaScript regular expression/,
  );
  assert.throws(() => matchChangedFiles('', changedFiles), /pattern is required/);
});
