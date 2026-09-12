import eslint from '@eslint/js';
import eslintConfigPrettier from 'eslint-config-prettier';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: ['.tools/**', '**/dist/**', 'node_modules/**'],
  },
  {
    files: ['**/*.ts'],
    extends: [
      eslint.configs.recommended,
      ...tseslint.configs.recommendedTypeChecked,
      ...tseslint.configs.stylisticTypeChecked,
      eslintConfigPrettier,
    ],
    rules: {
      curly: ['error', 'all'],
      'no-restricted-imports': [
        'error',
        {
          paths: [
            {
              name: 'node:child_process',
              message: 'TypeScript must not execute external commands; use a shell boundary instead.',
            },
            {
              name: 'child_process',
              message: 'TypeScript must not execute external commands; use a shell boundary instead.',
            },
          ],
        },
      ],
    },
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },
);
