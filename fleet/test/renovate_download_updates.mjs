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
  {
    packageName: 'crate-ci/typos', name: 'TYPOS', oldTag: 'v1.50.2', newTag: 'v1.51.0',
    oldUrl: 'https://github.com/crate-ci/typos/releases/download/v1.50.2/typos-v1.50.2-x86_64-unknown-linux-musl.tar.gz',
    newUrl: 'https://github.com/crate-ci/typos/releases/download/v1.51.0/typos-v1.51.0-x86_64-unknown-linux-musl.tar.gz',
    comment: '# Preserve this explanation about v1.50.2.',
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
  const typos = cases.find(fixture => fixture.name === 'TYPOS');
  const config = preset.customManagers.find(manager => manager.packageNameTemplate === typos.packageName);
  const otherDigest = 'c'.repeat(64);
  const step = (digest, url) => `      - name: Install typos
        env:
          TYPOS_SHA256: "${digest}"
        run: |
          archive="\${RUNNER_TEMP}/typos.tar.gz"

          curl --output "\${archive}" "${url}"
`;
  const linuxStep = step(oldDigest, typos.oldUrl);
  const macStep = step(otherDigest, typos.oldUrl.replace('x86_64-unknown-linux-musl', 'aarch64-apple-darwin'));
  const missingStep = step(otherDigest, 'https://example.invalid/no-typos-download');
  for (const [name, prefix] of [
    ['other-platform-job', `  macos:
    runs-on: macos-latest
    steps:
${macStep}  lint:
    runs-on: ubuntu-latest
    steps:
`],
    ['other-platform-step', `  lint:
    runs-on: ubuntu-latest
    steps:
${macStep}`],
    ['missing-download', `  lint:
    runs-on: ubuntu-latest
    steps:
${missingStep}`],
    ['two-linux-downloads', `  lint:
    runs-on: ubuntu-latest
    steps:
${step(otherDigest, typos.oldUrl)}`],
  ]) {
    for (const eol of ['\n', '\r\n']) {
      const source = `name: Download tools\njobs:\n${prefix}${linuxStep}`.replaceAll('\n', eol);
      const packageFile = `.github/workflows/typos-${name}-${eol.length}.yml`;
      const extracted = extractPackageFile(source, packageFile, config);
      assert.equal(extracted.deps.length, name === 'two-linux-downloads' ? 2 : 1, name);
      const depIndex = extracted.deps.length - 1;
      assert.equal(extracted.deps[depIndex].currentDigest, oldDigest, `${name}: bind the Linux checksum`);
      if (depIndex) assert.equal(extracted.deps[0].currentDigest, otherDigest);
      const updated = await doAutoReplace({
        ...config, ...extracted, ...extracted.deps[depIndex], manager: 'regex', packageFile, depIndex,
        autoReplaceGlobalMatch: true, newValue: typos.newTag, newDigest,
      }, source, false);
      const expected = source.replace(linuxStep.replaceAll('\n', eol),
        linuxStep.replace(oldDigest, newDigest).replace(typos.oldUrl, typos.newUrl).replaceAll('\n', eol));
      assert.equal(updated, expected, `${name}: update only the selected download`);
      assert.ok(parse(updated).jobs.lint);
    }
  }
  process.stdout.write(`Renovate download updates: ${cases.length * 3 + 8} real file-update cases passed.\n`);
} finally {
  GlobalConfig.reset();
  await rm(localDir, { recursive: true, force: true });
}
