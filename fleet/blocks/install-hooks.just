# Install git hooks (DCO sign-off + pre-push checks). Run once per clone.
install-hooks:
    git config core.hooksPath .githooks
