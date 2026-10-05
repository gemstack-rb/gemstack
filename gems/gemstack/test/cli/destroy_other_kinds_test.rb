# frozen_string_literal: true

require_relative "destroy_generator_test"

# `gemstack destroy job|policy|migration|deploy` reverses what the matching
# `gemstack generate` wrote, with the same safety rules as for resources.
class DestroyJobAndPolicyTest < Minitest::Test
  include DestroyTestSupport

  def job(name = "SendDigest")
    FileUtils.mkdir_p(File.join(@root, "db/migrations"))
    GemStack::CLI::JobGenerator.new(name, root: @root, output: @output).run
  end

  def policy(name = "Order")
    GemStack::CLI::PolicyGenerator.new(name, root: @root, output: @output).run
  end

  def test_job_removes_its_files_but_keeps_shared_ones
    job
    job("WeeklyReport")
    removal = destroy("job", "SendDigest")

    refute exists?("app/jobs/send_digest.rb")
    refute exists?("test/jobs/send_digest_test.rb")
    assert exists?("app/jobs/weekly_report.rb"), "other jobs stay"
    assert exists?("app/jobs/application_job.rb"), "the base class is shared"
    assert_equal 1, Dir["#{@root}/db/migrations/*_create_gemstack_jobs.rb"].size, "the jobs table is shared"
    refute_predicate removal, :contract_affected?, "jobs aren't part of the API contract"
  end

  def test_job_names_resolve_like_the_generator
    job("send_digest")
    destroy("job", "SendDigest")

    refute exists?("app/jobs/send_digest.rb")
  end

  def test_job_still_referenced_is_refused
    job
    write("app/models/user.rb", "class User\n  def welcome = SendDigest.perform_later(id)\nend\n")
    before = snapshot

    error = assert_raises(Thor::Error) { destroy("job", "SendDigest") }

    assert_includes error.message, "Remaining Ruby reference to SendDigest: app/models/user.rb"
    assert_equal before, snapshot
  end

  def test_edited_job_needs_force
    job
    write("app/jobs/send_digest.rb", "#{read("app/jobs/send_digest.rb")}# edited\n")

    assert_raises(Thor::Error) { destroy("job", "SendDigest") }
    destroy("job", "SendDigest", force: true)

    refute exists?("app/jobs/send_digest.rb")
  end

  def test_policy_removes_its_files
    policy
    destroy("policy", "Order")

    refute exists?("app/policies/order_policy.rb")
    refute exists?("test/policies/order_policy_test.rb")
  end

  def test_policy_still_referenced_is_refused
    policy
    write("app/controllers/orders_controller.rb", "class OrdersController\n  POLICY = OrderPolicy\nend\n")

    error = assert_raises(Thor::Error) { destroy("policy", "Order") }

    assert_includes error.message, "Remaining Ruby reference to OrderPolicy"
  end
end

class DestroyDeployTest < Minitest::Test
  include DestroyTestSupport

  GEMFILE = %(source "https://rubygems.org"\n\ngem "gemstack", "~> 0.3.5"\n)
  FILES = %w[Dockerfile .dockerignore config/deploy.yml .kamal/secrets bin/docker-entrypoint].freeze

  def setup
    super
    write("Gemfile", GEMFILE)
    write("config/database.yml", "production:\n  adapter: postgresql\n")
    GemStack::CLI::DeployGenerator.new(root: @root, output: @output).run
  end

  def test_removes_the_deploy_files_and_the_kamal_gem
    FILES.each { |path| assert exists?(path), path }
    removal = destroy("deploy", nil)

    FILES.each { |path| refute exists?(path), path }
    assert_equal GEMFILE, read("Gemfile")
    assert_includes @output.string, "Run bundle install"
    refute_predicate removal, :contract_affected?
  end

  def test_an_edited_kamal_line_is_left_alone
    write("Gemfile", read("Gemfile").sub("require: false,", "require: false, # pinned by us\n   "))
    destroy("deploy", nil)

    assert_includes read("Gemfile"), "kamal"
    refute exists?("config/deploy.yml")
  end

  def test_an_edited_deploy_file_needs_force
    write("config/deploy.yml", "#{read("config/deploy.yml")}# servers: real ones\n")
    before = snapshot

    assert_raises(Thor::Error) { destroy("deploy", nil) }
    assert_equal before, snapshot
    destroy("deploy", nil, force: true)

    refute exists?("config/deploy.yml")
  end

  def test_dry_run_changes_nothing
    before = snapshot
    destroy("deploy", nil, dry_run: true)

    assert_equal before, snapshot
    assert_includes @output.string, "ungem"
  end
end

class DestroyMigrationKindTest < Minitest::Test
  include DestroyMigrationSupport

  def generate_migration(name = "AddStockToPosts", fields = %w[stock:integer])
    GemStack::CLI::MigrationGenerator.new(name, fields, root: @root, output: @output).run
    Dir["#{@root}/db/migrations/*_#{GemStack::Inflector.underscore(name)}.rb"].first
  end

  def test_pending_uncommitted_migration_is_removed
    path = generate_migration

    destroy("migration", "AddStockToPosts")

    refute File.exist?(path)
  end

  def test_committed_migration_is_kept_unless_asked
    path = generate_migration
    commit_generated_files

    destroy("migration", "AddStockToPosts")

    assert File.exist?(path)
    assert_includes @output.string, "pending but committed to Git"
    destroy("migration", "AddStockToPosts", remove_migrations: true)

    refute File.exist?(path)
  end

  def test_applied_migration_is_kept
    resource(parts: %i[migration model serializer])
    path = generate_migration
    migrate

    destroy("migration", "AddStockToPosts", remove_migrations: true)

    assert File.exist?(path)
    assert_includes @output.string, "already applied"
  end
end
