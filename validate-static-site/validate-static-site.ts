import * as core from '@actions/core';
import { lstat, readdir } from 'node:fs/promises';
import { relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

function fail(message: string): never {
  throw new Error(message);
}

function displayPath(root: string, entry: string): string {
  return relative(root, entry) || '.';
}

async function inspectTree(root: string, directory: string): Promise<void> {
  const entries = await readdir(directory);
  for (const entry of entries) {
    const candidate = resolve(directory, entry);
    const stats = await lstat(candidate);
    if (stats.isSymbolicLink()) {
      fail(`static site must not contain symbolic links: ${displayPath(root, candidate)}`);
    }
    if (stats.isDirectory()) {
      await inspectTree(root, candidate);
      continue;
    }
    if (!stats.isFile()) {
      fail(`static site may contain only directories and regular files: ${displayPath(root, candidate)}`);
    }
  }
}

export async function validateStaticSite(path: string): Promise<void> {
  const root = resolve(path);
  let rootStats;
  try {
    rootStats = await lstat(root);
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') {
      fail(`static site path does not exist: ${path}`);
    }
    throw error;
  }

  if (rootStats.isSymbolicLink() || !rootStats.isDirectory()) {
    fail(`static site path must be a directory and not a symbolic link: ${path}`);
  }

  const rootEntries = await readdir(root);
  if (rootEntries.length === 0) {
    fail(`static site directory is empty: ${path}`);
  }

  const index = resolve(root, 'index.html');
  let indexStats;
  try {
    indexStats = await lstat(index);
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') {
      fail(`static site must contain a root index.html: ${path}`);
    }
    throw error;
  }
  if (indexStats.isSymbolicLink() || !indexStats.isFile()) {
    fail(`static site root index.html must be a regular file and not a symbolic link: ${path}`);
  }

  await inspectTree(root, root);
}

export async function run(): Promise<void> {
  try {
    const path = core.getInput('path', { required: true });
    await validateStaticSite(path);
    core.info(`Static site is valid: ${path}`);
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : 'Unknown error occurred');
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  void run();
}
