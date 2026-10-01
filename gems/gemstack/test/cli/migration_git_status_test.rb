# frozen_string_literal: true

require "test_helper"
require "open3"

class MigrationGitStatusTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("gemstack-migration-git")
    @path = "db/migrations/20260930120000_create_posts.rb"
    FileUtils.mkdir_p(File.dirname("#{@root}/#{@path}"))
    File.write("#{@root}/#{@path}", "# migration\n")
    git("init", "--quiet")
    git("config", "user.email", "test@gemstack.local")
    git("config", "user.name", "GemStack Test")
  end

  def teardown = FileUtils.remove_entry(@root)

  def git(*)
    output, error, status = Open3.capture3("git", "-C", @root, *)
    assert status.success?, output + error
  end

  def status(root = @root, path = @path)
    GemStack::CLI::MigrationGitStatus.new(root).committed(path)
  end

  def commit
    git("add", ".")
    git("commit", "--quiet", "-m", "Migration fixture")
  end

  def test_untracked_and_staged_files_in_a_new_repository_are_uncommitted
    assert_equal false, status
    git("add", ".")
    assert_equal false, status
  end

  def test_committed_files_are_detected
    commit
    assert_equal true, status
  end

  def test_app_nested_inside_a_repository_uses_the_correct_path
    nested = "#{@root}/apps/shop"
    FileUtils.mkdir_p(nested)
    FileUtils.mv("#{@root}/db", nested)
    commit
    assert_equal true, status(nested)
  end

  def test_previously_committed_files_are_protected_after_deletion_and_restoration
    commit
    git("rm", @path)
    commit
    FileUtils.mkdir_p(File.dirname("#{@root}/#{@path}"))
    File.write("#{@root}/#{@path}", "# restored migration\n")
    assert_equal true, status
  end

  def test_no_repository_is_unknown
    FileUtils.remove_entry("#{@root}/.git")
    assert_nil status
  end

  def test_missing_git_is_unknown
    Open3.stub(:capture3, ->(*) { raise Errno::ENOENT }) do
      assert_nil status
    end
  end

  def test_failed_history_query_is_unknown
    inspector = GemStack::CLI::MigrationGitStatus.new(@root)
    inspector.stub(:git, ->(*args) { "true" if args.include?("--is-inside-work-tree") }) do
      assert_nil inspector.committed(@path)
    end
  end

  def test_shallow_history_cannot_prove_a_migration_was_never_committed
    commit
    File.write("#{@root}/new_file", "fixture")
    commit
    git("clone", "--quiet", "--depth", "1", "file://#{@root}", "#{@root}/shallow")
    assert_equal true, status("#{@root}/shallow")
    assert_nil status("#{@root}/shallow", "db/migrations/untracked.rb")
  end
end
