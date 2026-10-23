import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { GlobalConfig } from '../validator/node_modules/renovate/dist/config/global.js';
import { getConfig } from '../validator/node_modules/renovate/dist/config/defaults.js';
import { init } from '../validator/node_modules/renovate/dist/logger/index.js';
import { extractPackageFile } from '../validator/node_modules/renovate/dist/modules/manager/custom/regex/index.js';
import { doAutoReplace } from '../validator/node_modules/renovate/dist/workers/repository/update/branch/auto-replace.js';
import { CustomDatasource } from '../validator/node_modules/renovate/dist/modules/datasource/custom/index.js';
import { lookupUpdates } from '../validator/node_modules/renovate/dist/workers/repository/process/lookup/index.js';
import { applyPackageRules } from '../validator/node_modules/renovate/dist/util/package-rules/index.js';
import { branchifyUpgrades } from '../validator/node_modules/renovate/dist/workers/repository/updates/branchify.js';
import { regexEngineStatus } from '../validator/node_modules/renovate/dist/util/regex.js';

const preset = JSON.parse(await readFile(new URL('../../renovate-config.json', import.meta.url)));
const candidate = JSON.parse(await readFile(new URL('./fixtures/ruby-runtime-renovate.json', import.meta.url)));
const managers = preset.customManagers.filter(manager => manager.datasourceTemplate === 'custom.ruby-builder-ubuntu');
assert.deepEqual(managers, candidate.customManagers, 'fixture managers must be the shipped manager definitions');
const localDir = await mkdtemp(join(tmpdir(), 'fleet-ruby-renovate-'));
const rendered = spawnSync('ruby', [fileURLToPath(new URL('./render_ruby_runtime_fixtures.rb', import.meta.url)), localDir], { encoding: 'utf8' });
assert.equal(rendered.status, 0, `canonical stubs must render: ${rendered.stderr}`);
const profiles = JSON.parse(rendered.stdout);
assert.ok(profiles.length > 1, 'canonical companion declarations must be present');
const combined = profiles.find(profile => profile.name === 'combined');
const companionRules = JSON.parse(await readFile(combined.stub, 'utf8')).packageRules;
const base = { ...getConfig(), ...preset, packageRules: [...preset.packageRules, ...companionRules], errors: [], warnings: [], repoIsOnboarded: true };
const oldDigest = 'a'.repeat(64);
const newDigest = 'b'.repeat(64);
const release = (version, digest) => ({
  tag_name: `ruby-${version}`, draft: false, prerelease: false, published_at: '2020-01-01T00:00:00Z',
  html_url: `https://github.com/ruby/ruby-builder/releases/tag/ruby-${version}`,
  assets: [{ name: `ruby-${version}-ubuntu-24.04-x64.tar.gz`, state: 'uploaded', digest: `sha256:${digest}`, created_at: '2020-01-01T00:01:00Z', updated_at: '2020-01-01T00:02:00Z' }],
});
const current = release('4.0.7', oldDigest);
const next = release('4.0.8', newDigest);
const lock = 'GEM\n  remote: https://rubygems.org/\n  specs:\n    rake (13.3.1)\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  rake\n\nRUBY VERSION\n   ruby 4.0.7\n\nBUNDLED WITH\n   4.0.15\n';
const files = { '.ruby-version': '4.0.7\n', '.ruby-version.sha256': `${oldDigest}  ruby-4.0.7-ubuntu-24.04-x64.tar.gz\n`, 'Gemfile.lock': lock };
await init();
GlobalConfig.set({ localDir });
let serial = 0;
async function consistencyCheck(contents, requireLock = true, runtime = combined.runtime) {
  const directory = join(localDir, `check-${serial++}`);
  await mkdir(directory);
  for (const [path, content] of Object.entries(contents)) {
    await mkdir(dirname(join(directory, path)), { recursive: true });
    await writeFile(join(directory, path), content);
  }
  const configPath = join(directory, 'scope.json');
  await writeFile(configPath, JSON.stringify({ params: { 'ruby-runtime': {
    ...runtime, 'require-lock-version': requireLock,
  } } }));
  return spawnSync('ruby', [fileURLToPath(new URL('../ruby_runtime.rb', import.meta.url)), 'check', directory, configPath], { encoding: 'utf8' });
}
async function pipeline(contents, metadata, rules = companionRules, source = preset) {
  const registry = join(localDir, `releases-${serial++}.json`);
  await writeFile(registry, JSON.stringify(metadata));
  const config = { ...base, ...source, packageRules: [...source.packageRules, ...rules], customDatasources: { 'ruby-builder-ubuntu': {
    ...source.customDatasources['ruby-builder-ubuntu'], defaultRegistryUrlTemplate: `file://${registry}`,
  } } };
  const extractedFiles = [];
  for (const [packageFile, content] of Object.entries(contents)) {
    for (const manager of source.customManagers.filter(manager => manager.datasourceTemplate === 'custom.ruby-builder-ubuntu')) {
      if (!manager.managerFilePatterns.some(pattern => new RegExp(pattern.slice(1, -1)).test(packageFile))) continue;
      const extracted = extractPackageFile(content, packageFile, manager);
      if (!extracted) continue;
      const deps = [];
      for (const dep of extracted.deps) {
        const lookupConfig = await applyPackageRules({ ...config, ...dep, packageFile, manager: 'custom.regex' });
        assert.notEqual(lookupConfig.enabled, false, 'configured companion must be enabled before lookup');
        const { val: result, err } = (await lookupUpdates(lookupConfig)).unwrap();
        assert.equal(err, undefined);
        assert.deepEqual(result.warnings, []);
        deps.push({ ...dep, ...result });
      }
      extractedFiles.push({ ...manager, ...extracted, packageFile, deps });
    }
  }
  const result = await branchifyUpgrades(config, { 'custom.regex': extractedFiles });
  const pendingBranches = result.branches.filter(branch => branch.upgrades.every(update => update.pendingChecks));
  const branches = result.branches.filter(branch => !pendingBranches.includes(branch));
  const output = { ...contents };
  for (const branch of branches) {
    for (const upgrade of branch.upgrades) {
      const updated = await doAutoReplace({ ...upgrade, manager: 'regex', autoReplaceGlobalMatch: true }, output[upgrade.packageFile], false);
      assert.ok(updated !== null, `Renovate rejected ${upgrade.packageFile}`);
      output[upgrade.packageFile] = updated;
    }
  }
  return { branches, pendingBranches, branchList: result.branchList, output };
}
function assertPending(result, paths) {
  assert.equal(result.branches.length, 0);
  assert.equal(result.pendingBranches.length, 1);
  const branch = result.pendingBranches[0];
  assert.equal(branch.branchName, 'renovate/ruby-4.x');
  assert.deepEqual(branch.upgrades.map(upgrade => upgrade.packageFile).sort(), paths.sort());
  assert.ok(branch.upgrades.every(upgrade => upgrade.pendingChecks === true));
  assert.ok(result.branchList.includes(branch.branchName), 'pending branch remains in the desired branch list');
}
const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
try {
  process.stdout.write(`Renovate regex engine: ${regexEngineStatus.type}\n`);
  const pairedNative = await applyPackageRules({ ...base, manager: 'ruby-version', packageFile: '.ruby-version', datasource: 'ruby-version', depName: 'ruby' });
  assert.equal(pairedNative.enabled, false, 'no competing native runtime owner');
  const singleton = await applyPackageRules({ ...getConfig(), ...preset, manager: 'custom.regex', packageFile: '.ruby-version', datasource: 'custom.ruby-builder-ubuntu' });
  assert.equal(singleton.enabled, false, 'custom managers are opt-in for companion-bearing runtimes');
  const normal = await pipeline(files, [current, next]);
  assert.equal(normal.branches.length, 1, 'one bot branch');
  assert.equal(normal.branches[0].branchName, 'renovate/ruby-4.x', 'retain the established branch name; hosted reuse remains conditional');
  assert.deepEqual(normal.branches[0].upgrades.map(u => u.packageFile).sort(), Object.keys(files).sort(), 'all three companions in the same real Renovate branch');
  assert.equal(normal.output['.ruby-version'], '4.0.8\n');
  assert.equal((await consistencyCheck(normal.output)).status, 0, 'normal Renovate output passes the real CI checker');
  assert.equal(normal.output['.ruby-version.sha256'], `${newDigest}  ruby-4.0.8-ubuntu-24.04-x64.tar.gz\n`);
  assert.equal(normal.output['Gemfile.lock'], lock.replace('ruby 4.0.7', 'ruby 4.0.8'), 'gem resolutions and Bundler bytes unchanged');
  process.stdout.write(`${JSON.stringify({ branch: normal.branches[0].branchName, updates: normal.branches[0].upgrades.map(({ packageFile, newValue, newDigest }) => ({ packageFile, newValue, newDigest })) })}\n`);
  assert.equal((await pipeline(normal.output, [current, next])).branches.length, 0, 'idempotence');
  const partial = await pipeline({ ...files, '.ruby-version': '4.0.8\n' }, [current, next]);
  assert.deepEqual(partial.output, normal.output, 'repair valid partial baseline');
  const currentChecksum = await pipeline({ ...files, '.ruby-version.sha256': normal.output['.ruby-version.sha256'] }, [current, next]);
  assert.deepEqual(currentChecksum.output, normal.output, 'repair reverse partial baseline');
  const absentSection = lock.replace('RUBY VERSION\n   ruby 4.0.7\n\n', '');
  const withoutSection = await pipeline({ ...files, 'Gemfile.lock': absentSection }, [current, next]);
  assert.equal(withoutSection.output['Gemfile.lock'], absentSection, 'do not add a RUBY VERSION section');
  assert.equal((await consistencyCheck(withoutSection.output, false)).status, 0, 'legitimately absent lock metadata passes');
  assert.notEqual((await consistencyCheck(withoutSection.output, true)).status, 0, 'deleted required lock metadata fails');
  const invalid = [
    { ...next, assets: [] }, { ...next, assets: [...next.assets, next.assets[0]] },
    { ...next, draft: true }, { ...next, prerelease: true },
    ...[undefined, null, '', 'not-a-date', '2026-99-99T99:99:99Z', '2023-02-29T00:00:00Z', '2026-04-31T00:00:00Z', 123, {}, []].flatMap(timestamp => [
      { ...next, published_at: timestamp },
      { ...next, assets: [{ ...next.assets[0], updated_at: timestamp }] },
    ]),
    { ...next, assets: [{ ...next.assets[0], state: 'starter' }] },
    { ...next, assets: [{ ...next.assets[0], name: 'ruby-4.0.8-ubuntu-22.04-x64.tar.gz' }] },
    ...[undefined, null, '', 'sha256:bad', `sha512:${'e'.repeat(128)}`].map(digest => ({ ...next, assets: [{ ...next.assets[0], digest }] })),
  ];
  for (const metadata of invalid) {
    const result = await pipeline(files, [current, metadata]);
    assert.equal(result.branches.length, 0, 'ineligible asset must produce no partial branch');
    assert.equal(result.pendingBranches.length, 0, 'invalid metadata must not create a pending branch');
    assert.deepEqual(result.output, files);
  }
  const leapDay = await pipeline(files, [current, { ...next, published_at: '2024-02-29T00:00:00Z' }]);
  assert.deepEqual(leapDay.output, normal.output, 'valid leap-day timestamps remain eligible');
  const fresh = await pipeline(files, [current, { ...next, published_at: now }]);
  assertPending(fresh, Object.keys(files));
  const freshArchive = { ...next, assets: [{ ...next.assets[0], updated_at: now }] };
  assertPending(await pipeline(files, [current, freshArchive]), Object.keys(files));
  const allowedOverride = await pipeline(files, [current, { ...next, published_at: now }], companionRules, { ...preset, minimumReleaseAge: '0 days' });
  assert.deepEqual(allowedOverride.output, normal.output, 'an explicit age override retains complete companions');
  const datasource = new CustomDatasource();
  const metaFile = join(localDir, 'timestamp.json');
  await writeFile(metaFile, JSON.stringify([next]));
  const transformed = await datasource.getReleases({ datasource: 'custom.ruby-builder-ubuntu', packageName: 'ruby/ruby-builder', customDatasources: { 'ruby-builder-ubuntu': { ...preset.customDatasources['ruby-builder-ubuntu'], defaultRegistryUrlTemplate: `file://${metaFile}` } } });
  assert.equal(transformed.releases[0].releaseTimestamp, '2020-01-01T00:02:00.000Z', 'archive update determines the later timestamp');
  await writeFile(metaFile, JSON.stringify([{ ...next, published_at: '2020-01-02T00:00:00Z' }]));
  const laterPublication = await datasource.getReleases({ datasource: 'custom.ruby-builder-ubuntu', packageName: 'ruby/ruby-builder', customDatasources: { 'ruby-builder-ubuntu': { ...preset.customDatasources['ruby-builder-ubuntu'], defaultRegistryUrlTemplate: `file://${metaFile}` } } });
  assert.equal(laterPublication.releases[0].releaseTimestamp, '2020-01-02T00:00:00.000Z', 'publication wins when the archive timestamp is earlier');

  // A grouping rule cannot require a dependency that extraction never found.
  for (const badChecksum of [undefined, 'malformed checksum\n']) {
    const broken = { ...files, '.ruby-version.sha256': badChecksum };
    if (badChecksum === undefined) delete broken['.ruby-version.sha256'];
    const result = await pipeline(broken, [current, next]);
    assert.equal(result.branches.length, 1);
    assert.equal(result.output['.ruby-version'], '4.0.8\n');
    assert.equal(result.output['.ruby-version.sha256'], badChecksum);
    assert.notEqual((await consistencyCheck(result.output)).status, 0, 'the actual CI command rejects the incomplete Renovate branch');
    assert.equal(result.branches[0].upgrades.length, 2, 'reproduce incomplete branch, required consistency CI must reject it');
  }
  for (const profile of profiles.filter(profile => profile.name !== 'combined')) {
    const runtime = profile.runtime;
    const stub = JSON.parse(await readFile(profile.stub, 'utf8'));
    const declared = { [runtime['version-file']]: files['.ruby-version'] };
    for (const path of runtime['lock-files'] ?? []) declared[path] = lock.replace('   ruby', '  ruby');
    if (runtime['checksum-file']) declared[runtime['checksum-file']] = files['.ruby-version.sha256'];
    const result = await pipeline(declared, [current, next], stub.packageRules);
    assert.equal(result.branches.length, 1, 'each canonical declaration produces one complete update');
    assert.equal(result.branches[0].branchName, 'renovate/ruby-4.x');
    assert.deepEqual(result.branches[0].upgrades.map(upgrade => upgrade.packageFile).sort(), Object.keys(declared).sort());
    assert.equal(result.output[runtime['version-file']], '4.0.8\n');
    if (runtime['checksum-file']) assert.equal(result.output[runtime['checksum-file']], normal.output['.ruby-version.sha256']);
    for (const path of runtime['lock-files'] ?? []) assert.equal(result.output[path], declared[path].replace('ruby 4.0.7', 'ruby 4.0.8'));
    assert.equal((await consistencyCheck(result.output, runtime['require-lock-version'] ?? false, runtime)).status, 0);
    assert.equal((await pipeline(result.output, [current, next], stub.packageRules)).branches.length, 0);
    assertPending(await pipeline(declared, [current, freshArchive], stub.packageRules), Object.keys(declared));
    process.stdout.write(`Canonical rendered layout passed: ${runtime['version-file']} (${Object.keys(declared).length} files)\n`);
  }
  const crlfLock = lock.replaceAll('\n', '\r\n');
  const crlfResult = await pipeline({ ...files, 'Gemfile.lock': crlfLock }, [current, next]);
  assert.equal(crlfResult.output['Gemfile.lock'], crlfLock.replace('ruby 4.0.7', 'ruby 4.0.8'), 'preserve CRLF lock bytes');
  const malformedLock = await pipeline({ ...files, 'Gemfile.lock': lock.replace('ruby 4.0.7', 'ruby corrupt') }, [current, next]);
  assert.notEqual((await consistencyCheck(malformedLock.output)).status, 0, 'malformed existing lock metadata fails CI');
  const duplicateLock = await pipeline({ ...files, 'Gemfile.lock': `${lock}\nRUBY VERSION\n   ruby 4.0.7\n\n` }, [current, next]);
  assert.notEqual((await consistencyCheck(duplicateLock.output)).status, 0, 'duplicate lock metadata fails CI after replacement');
  const replacement = await pipeline({ ...files, '.ruby-version.sha256': files['.ruby-version.sha256'].replace(oldDigest, 'c'.repeat(64)) }, [current]);
  assert.equal(replacement.branches.length, 0, 'same-version digest replacements are not automated');
  for (const configPath of process.argv.slice(2)) {
    const standalone = JSON.parse(await readFile(configPath, 'utf8'));
    assert.deepEqual(standalone.customDatasources['ruby-builder-ubuntu'], preset.customDatasources['ruby-builder-ubuntu'], 'all Ruby datasource definitions must remain identical');
    const pair = { '.ruby-version': files['.ruby-version'], '.ruby-version.sha256': files['.ruby-version.sha256'] };
    const result = await pipeline(pair, [current, next], [], standalone);
    assert.equal(result.branches.length, 1);
    assert.equal(result.branches[0].branchName, 'renovate/ruby-4.x');
    assert.equal(result.branches[0].upgrades.length, 2);
    assert.equal(result.output['.ruby-version'], normal.output['.ruby-version']);
    assert.equal(result.output['.ruby-version.sha256'], normal.output['.ruby-version.sha256']);
    assert.equal((await pipeline(pair, [current, { ...next, assets: [] }], [], standalone)).branches.length, 0);
    assertPending(await pipeline(pair, [current, freshArchive], [], standalone), Object.keys(pair));
    process.stdout.write(`Standalone configured pipeline passed: ${configPath}\n`);
  }
  process.stdout.write('Ruby Renovate: one complete 4.0.7 -> 4.0.8 branch for valid inputs; age, metadata, partial baseline and idempotence pass. Missing/malformed companion produces an incomplete branch: the required consistency check must reject that branch.\n');
} finally {
  GlobalConfig.reset();
  await rm(localDir, { recursive: true, force: true });
}
