import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

async function evaluatePolicy(source) {
  const context = vm.createContext({});
  const sdk = new vm.SyntheticModule(["defineConfig"], function () {
    this.setExport("defineConfig", (value) => value);
  }, { context });
  const module = new vm.SourceTextModule(source, { context });
  await module.link((name) => {
    assert.equal(name, "@coderabbitai/config");
    return sdk;
  });
  await module.evaluate();
  return module.namespace.default;
}

const source = fs.readFileSync(new URL("../files/coderabbit.config.ts", import.meta.url), "utf8");
const policy = await evaluatePolicy(source);

const base = {
  platform: "GitHub",
  repo: { owner: "starhaven-io", name: "homebrew-tap", isPrivate: false, defaultBranch: "main" },
  pr: {
    author: "p-linnane", headBranch: "fix/parser", baseBranch: "main", isDraft: false,
    changedFiles: { status: "resolved", paths: ["src/main.rs"] },
  },
};
let checked = 0;
function check(label, changes, expected, evaluate = policy) {
  const input = {
    ...base, ...changes,
    repo: { ...base.repo, ...changes.repo },
    pr: changes.pr === null ? null : { ...base.pr, ...changes.pr },
  };
  const config = evaluate(input);
  assert.equal(config.chat.allow_non_org_members, false, label);
  assert.equal(config.reviews.request_changes_workflow, expected, label);
  assert.equal(config.reviews.allow_author_approval, false, label);
  assert.equal(config.reviews.auto_review.enabled, true, label);
  assert.equal(config.reviews.auto_review.ignore_usernames.length, 0, label);
  assert.equal(config.reviews.auto_review.auto_pause_after_reviewed_commits, 0, label);
  const filters = ["**/*.json", ...(input.repo.name === "macOSdb" ? ["!data/macos/**", "!data/xcode/**"] : [])];
  assert.equal(JSON.stringify(config.reviews.path_filters), JSON.stringify(filters), label);
  checked += 1;
}
function bot(label, repo, branch, paths, expected, evaluate = policy) {
  check(label, {
    repo: { name: repo },
    pr: { author: "starhaven-bot[bot]", headBranch: branch, changedFiles: { status: "resolved", paths } },
  }, expected, evaluate);
}

check("maintainer", {}, true);
check("contributor", { pr: { author: "contributor" } }, false);
check("author identity is exact", { pr: { author: "p-linnane-example" } }, false);
check("draft", { pr: { isDraft: true } }, false);
check("no PR", { pr: null }, false);
check("private repository", { repo: { isPrivate: true } }, false);
check("unknown visibility", { repo: { isPrivate: undefined } }, false);
check("another owner", { repo: { owner: "another-org" } }, false);
check("another provider", { platform: "GitLab" }, false);
check("another base", { pr: { baseBranch: "release" } }, false);
check("unknown default branch", { repo: { defaultBranch: "" }, pr: { baseBranch: "" } }, false);
for (const [author, branch] of [["dependabot[bot]", "dependabot/npm_and_yarn/site/lodash-4"], ["renovate[bot]", "renovate/rust-1.x"]]) {
  check(`${author} update`, { pr: { author, headBranch: branch } }, true);
  check(`${author} wrong branch`, { pr: { author, headBranch: "fix/arbitrary" } }, false);
  check(`${author} unavailable paths`, { pr: { author, headBranch: branch, changedFiles: { status: "unavailable", paths: [] } } }, false);
  check(`${author} empty paths`, { pr: { author, headBranch: branch, changedFiles: { status: "resolved", paths: [] } } }, false);
  for (const lock of ["Cargo.lock", "site/package-lock.json", "Gemfile.lock", "go.sum", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
    "Brewy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]) {
    check(`${author} ${lock} alone`, { pr: { author, headBranch: branch, changedFiles: { status: "resolved", paths: [lock] } } }, false);
  }
  check(`${author} manifest with lockfile`, { pr: { author, headBranch: branch, changedFiles: { status: "resolved", paths: ["site/package.json", "site/package-lock.json"] } } }, true);
  check(`${author} lock-named source`, { pr: { author, headBranch: branch, changedFiles: { status: "resolved", paths: ["src/lock.rs"] } } }, true);
}
check("maintainer lockfile alone", { pr: { changedFiles: { status: "resolved", paths: ["Cargo.lock"] } } }, true);
bot("fleet sync", "homebrew-tap", "fleet-sync-v2026.10.06.1", ["AGENTS.md"], true);
bot("malformed fleet version", "homebrew-tap", "fleet-sync-unreviewed", ["AGENTS.md"], false);
bot("fleet release not yet enrolled", ".github", "fleet-release-v2026.10.06.1", ["fleet/VERSION"], false);
bot("fleet release with workflow change", ".github", "fleet-release-v2026.10.06.1", ["fleet/VERSION", ".github/workflows/fleet-sync.yml"], false);
bot("fleet release in another repo", "midden", "fleet-release-v2026.10.06.1", ["fleet/VERSION"], false);
bot("cask bump", "homebrew-tap", "bump-midden-0.9.3", ["Casks/midden.rb"], true);
bot("different cask", "homebrew-tap", "bump-midden-0.9.3", ["Casks/pinprick.rb"], false);
bot("cask plus workflow", "homebrew-tap", "bump-midden-0.9.3", ["Casks/midden.rb", ".github/workflows/ci.yml"], false);
bot("cask in another repo", "midden", "bump-midden-0.9.3", ["Casks/midden.rb"], false);
bot("catalog update not yet enrolled", "macOSdb", "feat/data-macOS-27.2-26B5101f", ["data/macos/releases.json", "data/macos/releases/27/macOS-27.2-26B5101f.json"], false);
bot("catalog rescan not yet enrolled", "macOSdb", "fix/data-rescan-Xcode-27.1-27A9275-12345", ["data/xcode/releases.json"], false);
bot("catalog plus source", "macOSdb", "feat/data-macOS-27.2-26B5101f", ["data/macos/releases.json", "Sources/main.swift"], false);
bot("catalog unknown files", "macOSdb", "feat/data-macOS-27.2-26B5101f", [], false);
bot("catalog traversal", "macOSdb", "feat/data-macOS-27.2-26B5101f", ["data/macos/releases/../config.json"], false);
bot("wrapper bump not yet enrolled", "pinprick-action", "chore/pin-pinprick-0.28.0", ["action.yml", "README.md"], false);
bot("wrapper plus workflow", "pinprick-action", "chore/pin-pinprick-0.28.0", ["action.yml", ".github/workflows/release.yml"], false);
bot("unrecognized bot PR", "midden", "fix/anything", ["src/main.rs"], false);
check("human copying a bot branch", { pr: { author: "contributor", headBranch: "fleet-sync-v2026.10.06.1" } }, false);

for (const repo of [".github", "Brewy", "macOSdb", "midden", "pinprick", "pinprick-action", "pkgstory", "rakkan", "starhaven.io", "future-public-repo"]) {
  for (const [author, branch] of [
    ["p-linnane", "fix/parser"],
    ["dependabot[bot]", "dependabot/npm_and_yarn/site/lodash-4"],
    ["renovate[bot]", "renovate/rust-1.x"],
    ["starhaven-bot[bot]", "fleet-sync-v2026.10.06.1"],
  ]) {
    check(`${repo}: ${author} remains review-only`, {
      repo: { name: repo }, pr: { author, headBranch: branch },
    }, false);
  }
}
const pilotChecked = checked;
// Only widen enrollment in memory; run the production branch/path predicates unchanged.
const declaration = 'const formalReviewRepos = ["homebrew-tap"]';
assert.equal(source.split(declaration).length, 2, "pilot declaration must match exactly once");
const publicRepos = [".github", "Brewy", "homebrew-tap", "macOSdb", "midden", "pinprick", "pinprick-action", "pkgstory", "rakkan", "starhaven.io"];
const expanded = await evaluatePolicy(source.replace(declaration, `const formalReviewRepos = ${JSON.stringify(publicRepos)}`));
for (const [label, repo, branch, paths, expected] of [
  ["fleet sync", "midden", "fleet-sync-v2026.10.06.1", ["AGENTS.md"], true],
  ["malformed fleet version", "midden", "fleet-sync-unreviewed", ["AGENTS.md"], false],
  ["fleet release", ".github", "fleet-release-v2026.10.06.1", ["fleet/VERSION"], true],
  ["fleet release with workflow change", ".github", "fleet-release-v2026.10.06.1", ["fleet/VERSION", ".github/workflows/fleet-sync.yml"], false],
  ["fleet release in another repo", "midden", "fleet-release-v2026.10.06.1", ["fleet/VERSION"], false],
  ["catalog update", "macOSdb", "feat/data-macOS-27.2-26B5101f", ["data/macos/releases.json", "data/macos/releases/27/macOS-27.2-26B5101f.json"], true],
  ["catalog rescan", "macOSdb", "fix/data-rescan-Xcode-27.1-27A9275-12345", ["data/xcode/releases.json"], true],
  ["catalog plus source", "macOSdb", "feat/data-macOS-27.2-26B5101f", ["data/macos/releases.json", "Sources/main.swift"], false],
  ["catalog unknown files", "macOSdb", "feat/data-macOS-27.2-26B5101f", [], false],
  ["catalog traversal", "macOSdb", "feat/data-macOS-27.2-26B5101f", ["data/macos/releases/../config.json"], false],
  ["catalog wrong branch", "macOSdb", "fix/arbitrary", ["data/macos/releases.json"], false],
  ["catalog wrong repo", "midden", "feat/data-macOS-27.2-26B5101f", ["data/macos/releases.json"], false],
  ["wrapper bump", "pinprick-action", "chore/pin-pinprick-0.28.0", ["action.yml", "README.md"], true],
  ["wrapper plus workflow", "pinprick-action", "chore/pin-pinprick-0.28.0", ["action.yml", ".github/workflows/release.yml"], false],
  ["wrapper wrong branch", "pinprick-action", "fix/arbitrary", ["action.yml"], false],
  ["wrapper wrong repo", "midden", "chore/pin-pinprick-0.28.0", ["action.yml"], false],
]) {
  bot(`expanded: ${label}`, repo, branch, paths, expected, expanded);
}
check("expanded: private stays excluded", { repo: { name: "macOSdb", isPrivate: true } }, false, expanded);
check("expanded: future repo stays excluded", { repo: { name: "future-public-repo" } }, false, expanded);
console.log(`${checked} CodeRabbit approval scenarios passed (${pilotChecked} pilot, ${checked - pilotChecked} expanded)`);
