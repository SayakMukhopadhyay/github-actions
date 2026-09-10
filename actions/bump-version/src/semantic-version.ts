export function incrementVersion(version: string, increment: string): string {
  if (increment !== 'patch' && increment !== 'minor' && increment !== 'major') {
    throw new Error('increment must be patch, minor, or major');
  }

  const [majorText, minorText, patchText] = version.split('.');
  const major = BigInt(majorText);
  const minor = BigInt(minorText);
  const patch = BigInt(patchText);

  if (increment === 'major') {
    return `${major + 1n}.0.0`;
  }
  if (increment === 'minor') {
    return `${major}.${minor + 1n}.0`;
  }

  return `${major}.${minor}.${patch + 1n}`;
}
