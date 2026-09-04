import { readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { format } from 'prettier';
import { parse } from 'yaml';

interface ActionInput {
  default?: unknown;
  description?: unknown;
  required?: unknown;
}

interface ActionOutput {
  description?: unknown;
}

interface ActionMetadata {
  description?: unknown;
  inputs?: Record<string, ActionInput>;
  name?: unknown;
  outputs?: Record<string, ActionOutput>;
}

interface ConsumerAction {
  directory: string;
  metadata: ActionMetadata;
}

const repository = 'SayakMukhopadhyay/github-actions';
function repositoryRoot(): string {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
}

async function readConsumerActions(root: string): Promise<ConsumerAction[]> {
  const entries = await readdir(root, { withFileTypes: true });
  const actions = await Promise.all(
    entries
      .filter((entry) => entry.isDirectory())
      .map(async (entry) => {
        const metadataPath = path.join(root, entry.name, 'action.yaml');
        try {
          const source = await readFile(metadataPath, 'utf8');
          const metadata = parse(source) as ActionMetadata;
          return { directory: entry.name, metadata };
        } catch (error: unknown) {
          if (isFileMissing(error)) {
            return undefined;
          }
          throw error;
        }
      }),
  );

  return actions
    .filter((action): action is ConsumerAction => action !== undefined)
    .sort((left, right) => left.directory.localeCompare(right.directory));
}

function isFileMissing(error: unknown): error is NodeJS.ErrnoException {
  return typeof error === 'object' && error !== null && 'code' in error && error.code === 'ENOENT';
}

function hasOwn(object: object, property: string): boolean {
  return Object.prototype.hasOwnProperty.call(object, property);
}

function inputSchema(input: ActionInput): Record<string, unknown> {
  const schema: Record<string, unknown> = {
    type: ['string', 'number', 'boolean'],
  };

  if (typeof input.description === 'string') {
    schema.description = input.description;
  }
  if (hasOwn(input, 'default')) {
    schema.default = input.default;
  }

  return schema;
}

function actionCondition(action: ConsumerAction): Record<string, unknown> {
  const inputs = action.metadata.inputs ?? {};
  const properties = Object.fromEntries(
    Object.entries(inputs).map(([name, input]) => [name, inputSchema(input)]),
  );
  const callerRequired = Object.entries(inputs)
    .filter(([, input]) => input.required === true && !hasOwn(input, 'default'))
    .map(([name]) => name);
  const withSchema: Record<string, unknown> = {
    type: 'object',
    properties,
    additionalProperties: false,
  };

  if (callerRequired.length > 0) {
    withSchema.required = callerRequired;
  }

  const then: Record<string, unknown> = {
    properties: {
      with: withSchema,
    },
  };
  if (callerRequired.length > 0) {
    then.required = ['with'];
  }

  return {
    if: {
      properties: {
        uses: {
          const: `${repository}/${action.directory}@v1`,
        },
      },
      required: ['uses'],
    },
    then,
  };
}

function buildSchema(actions: ConsumerAction[]): Record<string, unknown> {
  const conditions = actions.map(actionCondition);

  return {
    $schema: 'http://json-schema.org/draft-07/schema#',
    $id: 'https://raw.githubusercontent.com/SayakMukhopadhyay/github-actions/v1/schemas/action-inputs.schema.json',
    title: 'SayakMukhopadhyay/github-actions v1 workflow inputs',
    type: 'object',
    properties: {
      jobs: {
        type: 'object',
        additionalProperties: {
          type: 'object',
          properties: {
            steps: {
              type: 'array',
              items: {
                type: 'object',
                allOf: conditions,
              },
            },
          },
        },
      },
    },
    $comment: `Only ${repository} reusable action references at @v1 are constrained by this overlay.`,
  };
}

export async function generateActionSchema(root = repositoryRoot()): Promise<void> {
  const actions = await readConsumerActions(root);
  const schema = buildSchema(actions);
  const destination = path.join(root, 'schemas', 'action-inputs.schema.json');
  await writeFile(
    destination,
    await format(JSON.stringify(schema), { parser: 'json', printWidth: 100 }),
    'utf8',
  );
}

if (
  process.argv[1] !== undefined &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  void generateActionSchema();
}
