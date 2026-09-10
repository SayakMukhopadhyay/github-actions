import * as core from '@actions/core';
import { createHash, randomUUID } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { chmod, mkdir, rename, rm } from 'node:fs/promises';
import path from 'node:path';
import { Transform, type TransformCallback } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { pathToFileURL } from 'node:url';

export const ARGOCD_VERSION = 'v3.5.2';
export const ARGOCD_LINUX_AMD64_SHA256 = 'd87058531d2aed735100636dd7664bdd49b862588993b571385c49494f9832c1';
export const ARGOCD_LINUX_AMD64_URL = 'https://github.com/argoproj/argo-cd/releases/download/v3.5.2/argocd-linux-amd64';

export interface VerifiedDownloadOptions {
  destination: string;
  expectedSha256: string;
  fetchImplementation?: typeof fetch;
  url: string;
}

export async function writeVerifiedDownload(options: VerifiedDownloadOptions): Promise<void> {
  const fetchImplementation = options.fetchImplementation ?? fetch;
  const response = await fetchImplementation(options.url, { redirect: 'follow' });
  if (!response.ok || response.body === null) {
    throw new Error(`Argo CD CLI download failed with HTTP ${String(response.status)}`);
  }

  const temporary = `${options.destination}.${randomUUID()}.tmp`;
  const hash = createHash('sha256');
  const hashingStream = new Transform({
    transform(chunk: Buffer, _encoding: BufferEncoding, callback: TransformCallback): void {
      hash.update(chunk);
      callback(null, chunk);
    },
  });
  try {
    await pipeline(response.body, hashingStream, createWriteStream(temporary, { flags: 'wx', mode: 0o700 }));
    const actualSha256 = hash.digest('hex');
    if (actualSha256 !== options.expectedSha256) {
      throw new Error(`Argo CD CLI checksum mismatch: expected ${options.expectedSha256}, received ${actualSha256}`);
    }
    await chmod(temporary, 0o755);
    await rename(temporary, options.destination);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
}

export async function installArgocd(runnerTemp: string): Promise<string> {
  if (process.platform !== 'linux' || process.arch !== 'x64') {
    throw new Error(
      `argocd-verify-deployment supports only Linux x64 runners; received ${process.platform}/${process.arch}`,
    );
  }
  if (runnerTemp.trim().length === 0 || !path.isAbsolute(runnerTemp)) {
    throw new Error('runner-temp must be an absolute path');
  }

  const directory = path.join(runnerTemp, 'argocd-verify-deployment');
  const destination = path.join(directory, `argocd-${ARGOCD_VERSION}-linux-amd64`);
  await mkdir(directory, { recursive: true });
  await writeVerifiedDownload({
    destination,
    expectedSha256: ARGOCD_LINUX_AMD64_SHA256,
    url: ARGOCD_LINUX_AMD64_URL,
  });
  return destination;
}

export async function run(): Promise<void> {
  try {
    core.setOutput('cli-path', await installArgocd(core.getInput('runner-temp')));
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : 'Unknown error occurred');
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  void run();
}
