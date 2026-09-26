# frozen_string_literal: true

require "open3"

# Git exports GIT_DIR to hooks, as an absolute path from a linked worktree, so
# a fixture command that inherits it acts on the developer's repository. Clear
# what git clears when it enters another repository: its repository-local
# variables, keeping command-line config. nil unsets a variable in the child.
local_names, status = Open3.capture2("git", "rev-parse", "--local-env-vars")
raise "git rev-parse --local-env-vars failed" unless status.success?

ISOLATED_GIT_ENV = (local_names.split - %w[GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT])
                   .to_h { |name| [name, nil] }.freeze
