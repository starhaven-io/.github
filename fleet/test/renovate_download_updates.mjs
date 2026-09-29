import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { GlobalConfig } from '../validator/node_modules/renovate/dist/config/global.js';
import { getConfig } from '../validator/node_modules/renovate/dist/config/defaults.js';
import { init } from '../validator/node_modules/renovate/dist/logger/index.js';
import { extractPackageFile } from '../validator/node_modules/renovate/dist/modules/manager/custom/regex/index.js';
import { doAutoReplace } from '../validator/node_modules/renovate/dist/workers/repository/update/branch/auto-replace.js';
import { parse } from '../validator/node_modules/yaml/dist/index.js';
import { CustomDatasource } from '../validator/node_modules/renovate/dist/modules/datasource/custom/index.js';
import { lookupUpdates } from '../validator/node_modules/renovate/dist/workers/repository/process/lookup/index.js';
import { flattenUpdates } from '../validator/node_modules/renovate/dist/workers/repository/updates/flatten.js';
import { applyPackageRules } from '../validator/node_modules/renovate/dist/util/package-rules/index.js';

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
    bounded: true,
    oldUrl: 'https://github.com/crate-ci/typos/releases/download/v1.50.2/typos-v1.50.2-x86_64-unknown-linux-musl.tar.gz',
    newUrl: 'https://github.com/crate-ci/typos/releases/download/v1.51.0/typos-v1.51.0-x86_64-unknown-linux-musl.tar.gz',
    comment: '# Preserve this explanation about v1.50.2.',
  },
  {
    packageName: 'EmbarkStudios/cargo-deny', name: 'CARGO_DENY', oldTag: '0.20.2', newTag: '0.21.0',
    bounded: true,
    oldUrl: 'https://github.com/EmbarkStudios/cargo-deny/releases/download/0.20.2/cargo-deny-0.20.2-x86_64-unknown-linux-musl.tar.gz',
    newUrl: 'https://github.com/EmbarkStudios/cargo-deny/releases/download/0.21.0/cargo-deny-0.21.0-x86_64-unknown-linux-musl.tar.gz',
    comment: '# Preserve this explanation about 0.20.2.',
  },
  {
    packageName: 'nextest-rs/nextest', name: 'CARGO_NEXTEST', oldTag: 'cargo-nextest-0.9.146', newTag: 'cargo-nextest-0.9.147',
    bounded: true,
    oldUrl: 'https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-0.9.146/cargo-nextest-0.9.146-x86_64-unknown-linux-musl.tar.gz',
    newUrl: 'https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-0.9.147/cargo-nextest-0.9.147-x86_64-unknown-linux-musl.tar.gz',
    comment: '# Preserve this explanation about cargo-nextest-0.9.146.',
  },
  {
    packageName: 'taiki-e/cargo-llvm-cov', name: 'CARGO_LLVM_COV', oldTag: 'v0.9.1', newTag: 'v0.10.0',
    bounded: true,
    oldUrl: 'https://github.com/taiki-e/cargo-llvm-cov/releases/download/v0.9.1/cargo-llvm-cov-x86_64-unknown-linux-musl.tar.gz',
    newUrl: 'https://github.com/taiki-e/cargo-llvm-cov/releases/download/v0.10.0/cargo-llvm-cov-x86_64-unknown-linux-musl.tar.gz',
    comment: '# Preserve this explanation about v0.9.1.',
  },
];
const localDir = await mkdtemp(join(tmpdir(), 'fleet-renovate-update-'));
GlobalConfig.set({ localDir });
try {
  const denyFixture = cases.find(fixture => fixture.name === 'CARGO_DENY');
  const release = (version, digest) => ({
    tag_name: version, draft: false, prerelease: false, published_at: '2020-01-01T00:00:00Z',
    html_url: `https://github.com/EmbarkStudios/cargo-deny/releases/tag/${version}`,
    assets: [
      { name: `cargo-deny-${version}-x86_64-unknown-linux-musl.tar.gz`, state: 'uploaded', digest: `sha256:${digest}` },
      { name: `cargo-deny-${version}-x86_64-unknown-linux-musl.tar.gz.sha256`, state: 'uploaded', digest: `sha256:${'c'.repeat(64)}` },
      { name: `cargo-deny-${version}-aarch64-unknown-linux-musl.tar.gz`, state: 'uploaded', digest: `sha256:${'d'.repeat(64)}` },
    ],
  });
  const current = release(denyFixture.oldTag, oldDigest);
  const next = release(denyFixture.newTag, newDigest);
  const invalidReleases = [
    { ...next, draft: true },
    { ...next, prerelease: true },
    { ...next, published_at: null },
    release(`${denyFixture.newTag}-rc.1`, newDigest),
    { ...next, assets: next.assets.slice(1) },
    { ...next, assets: [...next.assets, next.assets[0]] },
    ...[undefined, null, 'sha256:bad', `sha512:${'e'.repeat(128)}`].map(digest => ({
      ...next, assets: [{ ...next.assets[0], digest }],
    })),
    { ...next, assets: [{ ...next.assets[0], state: 'starter' }] },
  ];
  const releaseFile = join(localDir, 'deny-releases.json');
  const datasource = new CustomDatasource();
  const datasourceConfig = {
    datasource: 'custom.cargo-deny-linux', packageName: denyFixture.packageName,
    customDatasources: {
      'cargo-deny-linux': {
        ...preset.customDatasources['cargo-deny-linux'], defaultRegistryUrlTemplate: `file://${releaseFile}`,
      },
    },
  };
  await writeFile(releaseFile, JSON.stringify([current, next, ...invalidReleases]));
  const releases = await datasource.getReleases(datasourceConfig);
  assert.deepEqual(releases.releases.map(({ version, newDigest }) => [version, newDigest]),
    [[denyFixture.oldTag, oldDigest], [denyFixture.newTag, newDigest]],
    'select the exact archive digest, ignoring sidecars, other platforms and incomplete releases');
  assert.equal(releases.releases[1].releaseTimestamp, new Date(next.published_at).toISOString(), 'retain the seven-day age gate input');
  let lookupIndex = 0;
  const lookup = async (metadata, currentDigest = oldDigest) => {
    const path = join(localDir, `deny-lookup-${lookupIndex++}.json`);
    await writeFile(path, JSON.stringify(metadata));
    const config = {
      ...getConfig(), ...preset, ...datasourceConfig,
      manager: 'custom.regex', depName: 'cargo-deny', versioning: 'semver',
      currentValue: denyFixture.oldTag, currentDigest,
      customDatasources: {
        'cargo-deny-linux': {
          ...preset.customDatasources['cargo-deny-linux'], defaultRegistryUrlTemplate: `file://${path}`,
        },
      },
    };
    const { val: result, err } = (await lookupUpdates(config)).unwrap();
    assert.equal(err, undefined);
    assert.deepEqual(result.warnings, []);
    assert.equal(result.skipReason, undefined);
    const updates = await flattenUpdates(config, {
      'custom.regex': [{ packageFile: '.github/workflows/ci.yml', deps: [{ ...config, ...result }] }],
    });
    return { result, updates };
  };
  const normal = await lookup([current, next]);
  assert.deepEqual(normal.updates.map(({ updateType, newValue, newDigest }) => [updateType, newValue, newDigest]),
    [['minor', denyFixture.newTag, newDigest]], 'version updates carry the archive digest through lookup and filtering');
  const replaced = await lookup([current, next], 'e'.repeat(64));
  const digestUpdate = replaced.result.updates.find(update => update.updateType === 'digest');
  assert.equal(digestUpdate.newDigest, oldDigest, 'reproduce a replaced archive for the current release');
  assert.notEqual(digestUpdate.pendingChecks, true, 'an old release timestamp cannot age a replacement archive');
  assert.deepEqual(replaced.updates.map(({ updateType, newValue, newDigest }) => [updateType, newValue, newDigest]),
    [['minor', denyFixture.newTag, newDigest]], 'suppress checksum-only replacements without disabling version updates');
  assert.deepEqual((await lookup([current], 'e'.repeat(64))).updates, [],
    'a replacement archive alone must not produce an update');
  const fresh = await lookup([current, { ...next, published_at: new Date().toISOString() }]);
  assert.deepEqual(fresh.updates.filter(update => !update.pendingChecks), [], 'new versions retain the release-age gate');
  const unrelated = await applyPackageRules({ datasource: 'docker', updateType: 'digest', packageRules: preset.packageRules });
  assert.notEqual(unrelated.enabled, false, 'leave other datasources digest updates enabled');
  await writeFile(releaseFile, JSON.stringify(invalidReleases));
  assert.deepEqual((await datasource.getReleases(datasourceConfig)).releases, [],
    'missing or ambiguous binary metadata must not produce a version-only update');

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
  for (const fixture of cases.filter(fixture => fixture.bounded)) {
    const config = preset.customManagers.find(manager => manager.packageNameTemplate === fixture.packageName);
    const otherDigest = 'c'.repeat(64);
    const step = (digest, url) => `      - name: Install ${fixture.name}
        if: matrix.check == 'lint'
        env:
          ${fixture.name}_SHA256: "${digest}"
        run: |
          archive="\${RUNNER_TEMP}/archive.tar.gz"

          curl --output "\${archive}" "${url}"
`;
    const linuxStep = step(oldDigest, fixture.oldUrl);
    const macStep = step(otherDigest, fixture.oldUrl.replace('x86_64-unknown-linux-musl', 'aarch64-apple-darwin'));
    const missingStep = step(otherDigest, 'https://example.invalid/no-tool-download');
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
${step(otherDigest, fixture.oldUrl)}`],
    ]) {
      for (const eol of ['\n', '\r\n']) {
        const source = `name: Download tools\njobs:\n${prefix}${linuxStep}`.replaceAll('\n', eol);
        const packageFile = `.github/workflows/${fixture.name}-${name}-${eol.length}.yml`;
        const extracted = extractPackageFile(source, packageFile, config);
        assert.equal(extracted.deps.length, name === 'two-linux-downloads' ? 2 : 1, name);
        const depIndex = extracted.deps.length - 1;
        assert.equal(extracted.deps[depIndex].currentDigest, oldDigest, `${name}: bind the Linux checksum`);
        if (depIndex) assert.equal(extracted.deps[0].currentDigest, otherDigest);
        const updated = await doAutoReplace({
          ...config, ...extracted, ...extracted.deps[depIndex], manager: 'regex', packageFile, depIndex,
          autoReplaceGlobalMatch: true, newValue: fixture.newTag, newDigest,
        }, source, false);
        const expected = source.replace(linuxStep.replaceAll('\n', eol),
          linuxStep.replace(oldDigest, newDigest).replace(fixture.oldUrl, fixture.newUrl).replaceAll('\n', eol));
        assert.equal(updated, expected, `${name}: update only the selected download`);
        assert.ok(parse(updated).jobs.lint);
      }
    }
    const noncanonical = `name: Download tools\njobs:\n  lint:\n    runs-on: ubuntu-latest\n    steps:\n${linuxStep}`
      .replaceAll('\n      ', '\n        ');
    assert.equal(extractPackageFile(noncanonical, '.github/workflows/other-indent.yml', config), null,
      'unsupported indentation must not fall back to an unbounded match');
  }
  process.stdout.write(`Renovate download updates: ${cases.length * 3 + cases.filter(fixture => fixture.bounded).length * 8} real file-update cases passed.\n`);
} finally {
  GlobalConfig.reset();
  await rm(localDir, { recursive: true, force: true });
}
