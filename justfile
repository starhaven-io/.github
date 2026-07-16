# Check

# Run all checks
check:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=0
    skipped=()
    run() {
        echo "--- $1 ---"
        shift
        if ! "$@"; then
            failed=1
        fi
    }
    skip() {
        echo "--- $1 --- skipped ($2)"
        skipped+=("$2; install with: $3")
    }
    run diff git diff --check
    if ! command -v bundle &>/dev/null; then
        skip fleet-bundle "bundle not found" "brew install ruby"
    elif ! BUNDLE_GEMFILE=fleet/Gemfile bundle check &>/dev/null; then
        skip fleet-bundle "fleet bundle not installed" "BUNDLE_GEMFILE=fleet/Gemfile bundle install"
    else
        run guard-regressions env BUNDLE_GEMFILE=fleet/Gemfile bundle exec ruby fleet/test/guard_regressions_test.rb
        run rubocop env BUNDLE_GEMFILE=fleet/Gemfile bundle exec rubocop --config fleet/.rubocop.yml --cache false fleet/
    fi
    if command -v zizmor &>/dev/null; then
        run audit zizmor --persona auditor .github/workflows/
    else
        skip audit "zizmor not found" "brew install zizmor"
    fi
    if command -v pinprick &>/dev/null; then
        run pinprick-audit pinprick audit .
    else
        skip pinprick-audit "pinprick not found" "brew install pinprick"
    fi
    if command -v lychee &>/dev/null; then
        run lychee lychee --config lychee.toml README.md profile/README.md CONTRIBUTING.md SECURITY.md
    else
        skip lychee "lychee not found" "brew install lychee"
    fi
    if [ ${#skipped[@]} -gt 0 ]; then
        echo ""
        echo "Checks skipped:"
        for tool in "${skipped[@]}"; do
          echo "  - $tool"
        done
        failed=1
    fi
    exit "$failed"

# Lint the fleet renderer
rubocop:
    BUNDLE_GEMFILE=fleet/Gemfile bundle exec rubocop --config fleet/.rubocop.yml --cache false fleet/

# Run fleet guard security regression cases
guard-regressions:
    ruby fleet/test/guard_regressions_test.rb

# fleet:block audit
audit:
    zizmor --persona auditor .github/workflows/
# fleet:end

# fleet:block pinprick-audit
pinprick-audit:
    pinprick audit .
# fleet:end

# Check README, profile, and community-health links
lychee:
    lychee --config lychee.toml README.md profile/README.md CONTRIBUTING.md SECURITY.md

# Setup

# fleet:block install-hooks
# Install git hooks (DCO sign-off + pre-push checks). Run once per clone.
install-hooks:
    git config core.hooksPath .githooks
# fleet:end
