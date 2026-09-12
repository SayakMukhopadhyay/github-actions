import { defineConfig } from 'rolldown';

const bundles = [
  ['check-version/check-version.ts', 'check-version/dist/index.mjs'],
  ['actions/is-file-changed/is-file-changed.ts', 'actions/is-file-changed/dist/index.mjs'],
  ['actions/bump-version/src/index.ts', 'actions/bump-version/dist/index.mjs'],
  ['actions/helm-package-push/src/index.ts', 'actions/helm-package-push/dist/index.mjs'],
  ['actions/argocd-verify-deployment/argocd-verify-deployment.ts', 'actions/argocd-verify-deployment/dist/index.mjs'],
  ['actions/create-release/src/index.ts', 'actions/create-release/dist/index.mjs'],
  ['validate-static-site/validate-static-site.ts', 'validate-static-site/dist/index.mjs'],
  ['dispatch-pages-deployment/src/index.ts', 'dispatch-pages-deployment/dist/index.mjs'],
] as const;

export default defineConfig(
  bundles.map(([input, file]) => ({
    input,
    platform: 'node' as const,
    output: {
      codeSplitting: false,
      file,
      format: 'esm' as const,
      sourcemap: true,
    },
  })),
);
