import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { GlobalConfig } from '../validator/node_modules/renovate/dist/config/global.js';
import { init } from '../validator/node_modules/renovate/dist/logger/index.js';
import { extractPackageFile } from '../validator/node_modules/renovate/dist/modules/manager/custom/regex/index.js';
import { doAutoReplace } from '../validator/node_modules/renovate/dist/workers/repository/update/branch/auto-replace.js';
import { parse } from '../validator/node_modules/yaml/dist/index.js';

const preset = JSON.parse(await readFile(new URL('../../renovate-config.json', import.meta.url)));
await init();
const oldDigest = 'a'.repeat(64);
const newDigest = 'b'.repeat(64);
const cases = [
  {
    packageName: 'vale-cli/vale', name: 'VALE', oldTag: 'v3.19.0', newTag: 'v3.20.0',
    oldUrl: 'https://github.com/vale-cli/vale/releases/download/v3.19.0/vale_3.19.0_Linux_64-bit.tar.gz',
    newUrl: 'https://github.com/vale-cli/vale/releases/download/v3.20.0/vale_3.20.0_Linux_64-bit.tar.gz',
    comment: '# Preserve this explanation about 3.19.0 and v3.19.0.',
  },
  {
    packageName: 'lycheeverse/lychee', name: 'LYCHEE', oldTag: 'lychee-v0.24.2', newTag: 'lychee-v0.25.0',
    oldUrl: 'https://github.com/lycheeverse/lychee/releases/download/lychee-v0.24.2/lychee-x86_64-unknown-linux-gnu.tar.gz',
    newUrl: 'https://github.com/lycheeverse/lychee/releases/download/lychee-v0.25.0/lychee-x86_64-unknown-linux-gnu.tar.gz',
    comment: '# Preserve this explanation about 0.24.2.',
  },
];
const localDir = await mkdtemp(join(tmpdir(), 'fleet-renovate-update-'));
GlobalConfig.set({ localDir });
try {
  for (const fixture of cases) {
    const source = `name: Download tools
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Install ${fixture.name}
        env:
          ${fixture.name}_SHA256: "${oldDigest}"
        run: |
          ${fixture.comment}
          archive="\${RUNNER_TEMP}/archive.tar.gz"
          curl --fail --location --proto '=https' \\
            --output "\${archive}" \\
            "${fixture.oldUrl}"
          printf '%s  %s\\n' "\${${fixture.name}_SHA256}" "\${archive}" | sha256sum --check --strict
          tar -xzf "\${archive}"
`;
    const matches = preset.customManagers.filter(m => m.packageNameTemplate === fixture.packageName)
      .map(config => ({ config, extracted: extractPackageFile(source, '.github/workflows/ci.yml', config) }))
      .filter(({ extracted }) => extracted);
    assert.equal(matches.length, 1, `${fixture.name}: exactly one update owner`);
    const { config, extracted } = matches[0];
    assert.equal(extracted.deps.length, 1);
    assert.equal(extracted.deps[0].currentValue, fixture.oldTag, 'digest lookup requires the complete GitHub tag');
    assert.equal(extracted.deps[0].currentDigest, oldDigest);
    assert.equal(extracted.deps[0].between, undefined, 'arbitrary captures do not survive extraction');
    for (const mode of ['version-and-digest', 'digest-only', 'version-only']) {
      const packageFile = `.github/workflows/${fixture.name}-${mode}.yml`;
      const changesVersion = mode !== 'digest-only';
      const changesDigest = mode !== 'version-only';
      const upgrade = {
        ...config, ...extracted, ...extracted.deps[0], manager: 'regex', packageFile, depIndex: 0,
        autoReplaceGlobalMatch: true,
        newValue: changesVersion ? fixture.newTag : fixture.oldTag,
        ...(changesDigest ? { newDigest } : {}),
      };
      // Use Renovate's complete extraction -> file update -> re-extraction path.
      const updated = await doAutoReplace(upgrade, source, false);
      const expected = source.replace(oldDigest, changesDigest ? newDigest : oldDigest)
        .replace(fixture.oldUrl, changesVersion ? fixture.newUrl : fixture.oldUrl);
      assert.equal(updated, expected, `${fixture.name} ${mode}: preserve all non-pin bytes`);
      assert.equal(await readFile(join(localDir, packageFile), 'utf8'), expected);
      assert.equal(parse(updated).jobs.lint.steps.length, 1, 'updated workflow remains valid YAML');
      const after = extractPackageFile(updated, packageFile, config).deps[0];
      assert.equal(after.currentValue, upgrade.newValue);
      assert.equal(after.currentDigest, changesDigest ? newDigest : oldDigest);
    }
  }
  process.stdout.write('Renovate download updates: 6 real file-update cases passed.\n');
} finally {
  GlobalConfig.reset();
  await rm(localDir, { recursive: true, force: true });
}
