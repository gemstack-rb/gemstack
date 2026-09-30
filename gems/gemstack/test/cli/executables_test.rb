# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class CLIExecutablesTest < Minitest::Test
  REPO_ROOT = File.expand_path("../../../..", __dir__)

  def help_for(executable)
    path = File.join(REPO_ROOT, "bin", executable)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, path, "help", chdir: REPO_ROOT)
    assert status.success?, stderr
    stdout
  end

  def test_gemstack_help_uses_the_gemstack_executable_name
    help = help_for("gemstack")

    assert_includes help, "  gemstack dev"
    refute_includes help, "  gsk dev"
  end

  def test_gs_help_uses_the_short_executable_name
    help = help_for("gsk")

    assert_includes help, "  gsk dev"
    refute_includes help, "  gemstack dev"
  end
end
