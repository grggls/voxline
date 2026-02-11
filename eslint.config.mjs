import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  {
    ignores: ['**/dist/', '**/node_modules/', 'ui/'],
  },
  {
    files: ['**/*.js'],
    languageOptions: {
      globals: { module: 'readonly', require: 'readonly', __dirname: 'readonly' },
    },
  },
);
