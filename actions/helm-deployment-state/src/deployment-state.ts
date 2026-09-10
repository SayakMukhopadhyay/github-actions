import { existsSync, realpathSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { isMap, isSeq } from 'yaml';
import type { HelmDeploymentState, ReadHelmDeploymentStateOptions } from './contracts.ts';
import {
  ensureContained,
  optionalStringScalar,
  parseMapping,
  requiredInput,
  scalarValue,
  sourceRef,
} from './validation.ts';

function fail(message: string): never {
  throw new Error(message);
}

export function readHelmDeploymentState(options: ReadHelmDeploymentStateOptions): HelmDeploymentState {
  const chartName = requiredInput(options.chartName, 'chart-name');
  const environment = requiredInput(options.environment, 'environment');
  const requestedDependency = requiredInput(options.dependency || chartName, 'dependency');
  const requestedWrapper = options.wrapperChartPath || join(chartName, 'envs', environment);

  const checkout = realpathSync(options.checkoutPath);
  const lexicalWrapper = resolve(checkout, requestedWrapper);

  ensureContained(checkout, lexicalWrapper, 'wrapper-chart-path');

  if (!existsSync(lexicalWrapper)) {
    fail(`wrapper chart path does not exist: ${lexicalWrapper}`);
  }

  const wrapper = realpathSync(lexicalWrapper);
  ensureContained(checkout, wrapper, 'wrapper-chart-path');

  const chartFile = join(wrapper, 'Chart.yaml');
  const valuesFile = join(wrapper, 'values.yaml');
  const chart = parseMapping(chartFile);
  const values = parseMapping(valuesFile);

  const dependencies: unknown = chart.get('dependencies', true);

  if (!isSeq(dependencies)) {
    fail(`${chartFile} field dependencies must be a sequence`);
  }

  const matches: { versionNode: unknown; valuesRoot: string }[] = [];

  for (const dependency of dependencies.items) {
    if (!isMap(dependency)) {
      fail(`${chartFile} dependencies must be mappings`);
    }

    const name = optionalStringScalar(dependency.get('name', true), `${chartFile} dependency name`);

    if (name === undefined) {
      fail(`${chartFile} dependencies must have a name`);
    }

    const alias = optionalStringScalar(dependency.get('alias', true), `${chartFile} dependency alias`);

    if (requestedDependency === name || requestedDependency === alias) {
      matches.push({ versionNode: dependency.get('version', true), valuesRoot: alias ?? name });
    }
  }

  if (matches.length !== 1) {
    fail(
      `${chartFile} must contain exactly one dependency matching '${requestedDependency}'; found ${String(matches.length)}`,
    );
  }

  const match = matches[0] ?? fail('selected dependency was unavailable');
  const dependencyVersion = scalarValue(match.versionNode, `${chartFile} dependency version`);
  const rootNode: unknown = values.get(match.valuesRoot, true);

  if (!isMap(rootNode)) {
    fail(`${valuesFile} field ${match.valuesRoot} must be a mapping`);
  }

  const imageNode: unknown = rootNode.get('image', true);

  if (!isMap(imageNode)) {
    fail(`${valuesFile} field ${match.valuesRoot}.image must be a mapping`);
  }

  const imageTag = scalarValue(imageNode.get('tag', true), `${valuesFile} field ${match.valuesRoot}.image.tag`);

  return { dependencyVersion, imageTag, chartSourceRef: sourceRef(dependencyVersion) };
}
