// @ts-check
import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['node_modules/**', '.wrangler/**', 'dist/**'] },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      '@typescript-eslint/consistent-type-imports': 'error',
      '@typescript-eslint/no-floating-promises': 'error',
      '@typescript-eslint/no-unnecessary-condition': 'off',
      // ESLint's project service resolves `Response` from the DOM lib while
      // `tsc` uses @cloudflare/workers-types, where `json()` returns
      // `Promise<unknown>`. The rule therefore reports the casts that tsc
      // requires as unnecessary; tsc is the authority here.
      '@typescript-eslint/no-unnecessary-type-assertion': 'off',
      'no-restricted-globals': [
        'error',
        // Force explicit deadlines: bare fetch has no timeout in Workers.
        { name: 'setInterval', message: 'Use a Durable Object alarm instead of setInterval.' },
      ],
      eqeqeq: ['error', 'always', { null: 'ignore' }],
      'no-console': 'off',
    },
  },
  {
    files: ['test/**/*.ts'],
    rules: {
      '@typescript-eslint/no-non-null-assertion': 'off',
      '@typescript-eslint/no-unsafe-assignment': 'off',
      '@typescript-eslint/no-unsafe-member-access': 'off',
      '@typescript-eslint/no-unsafe-argument': 'off',
      '@typescript-eslint/no-unsafe-call': 'off',
    },
  },
);
