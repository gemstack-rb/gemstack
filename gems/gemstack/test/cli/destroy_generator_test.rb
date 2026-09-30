# frozen_string_literal: true

require "test_helper"
require "open3"

module DestroyTestSupport
  Manifest = GemStack::CLI::GenerationManifest

  def setup
    @root = Dir.mktmpdir("gemstack-destroy")
    @output = StringIO.new
    write("config/routes.rb", "# UTF-8 routes: → API\nGemStack.routes do\nend\n")
  end

  def teardown = FileUtils.remove_entry(@root)

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), content)
  end

  def read(path) = File.read(File.join(@root, path))
  def exists?(path) = File.exist?(File.join(@root, path))

  def snapshot
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).select { |path| File.file?(File.join(@root, path)) }
       .to_h { |path| [path, File.binread(File.join(@root, path))] }
  end

  def resource(name = "Post", fields: %w[title:string], **)
    spec = GemStack::CLI::ResourceSpec.new(name, fields)
    GemStack::CLI::ResourceGenerator.new(spec, root: @root, output: @output, **).run
  end

  def controller(name = "Reports", actions = %w[index show])
    GemStack::CLI::ControllerGenerator.new(name, actions, root: @root, output: @output).run
  end

  def destroy(kind = "resource", name = "Post", **, &)
    GemStack::CLI::DestroyGenerator.new(kind, name, root: @root, output: @output, **).run(&)
  end
end

module DestroyMigrationSupport
  include DestroyTestSupport

  def setup
    super

    gems = File.expand_path("../../..", __dir__)
    sqlite3_version = Gem.loaded_specs.fetch("sqlite3").version.to_s

    write("Gemfile", <<~RUBY)
      source "https://rubygems.org"

      path #{gems.inspect} do
        gem "gemstack"
      end

      gem "sqlite3", "= #{sqlite3_version}"
    RUBY

    write("config/app.rb", <<~RUBY)
      require "bundler/setup"
      require "gemstack/db"

      GemStack.setup(root: File.expand_path("..", __dir__))
      GemStack.config.db.log_queries = false
    RUBY

    write("config/database.yml", <<~YAML)
      development:
        adapter: sqlite3
        database: db/development.sqlite3
      test:
        adapter: sqlite3
        database: db/test.sqlite3
    YAML

    # Offline fixtures must resolve gems from the parent bundle.
    output, error, status = in_app(
      "env",
      "BUNDLE_LOCKFILE_CHECKSUMS=false",
      "bundle",
      "lock",
      "--local"
    )

    assert status.success?, output + error
    git("init", "--quiet")
  end

  def in_app(*command, environment: "development")
    bundle_path = ENV["BUNDLE_PATH"] || Bundler.settings[:path]&.to_s if defined?(Bundler)

    run = lambda do
      Open3.capture3(
        {
          "BUNDLE_GEMFILE" => "#{@root}/Gemfile",
          "BUNDLE_PATH" => bundle_path,
          "GEMSTACK_ENV" => environment,
          "DATABASE_URL" => nil,
          "TEST_DATABASE_URL" => nil
        },
        *command,
        chdir: @root
      )
    end

    defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
  end

  def git(*)
    output, error, status = Open3.capture3("git", *, chdir: @root)
    assert status.success?, output + error
  end

  def commit_generated_files
    git("init")
    git("config", "user.email", "test@gemstack.local")
    git("config", "user.name", "GemStack Test")
    git("add", ".")
    git("commit", "-m", "Add generated resource")
  end

  def app_eval(code, **)
    output, error, status = in_app("bundle", "exec", "ruby", "-r", "./config/app", "-e", code, **)
    assert status.success?, output + error
    output.strip
  end

  def destroy(kind = "resource", name = "Post", **, &)
    super(kind, name, environment: "development", **, &)
  end

  def migrations = Dir["#{@root}/db/migrations/*_create_posts.rb"]

  def migrate(environment: "development")
    app_eval("GemStack::DB::Migrator.new.migrate", environment: environment)
  end
end

class DestroyGitMigrationTest < Minitest::Test
  include DestroyMigrationSupport

  def test_pending_locally_but_committed_migration_is_preserved
    resource(parts: %i[migration model serializer])
    path = migrations.first

    commit_generated_files
    migrate(environment: "test")

    destroy("model")

    assert File.exist?(path)
    assert_includes @output.string, "pending but committed to Git"
    migrate(environment: "test")
    assert_equal "true", app_eval("puts GemStack.db.table_exists?(:posts)", environment: "test")
  end

  def test_remove_migrations_removes_committed_pending_migration
    resource(parts: %i[migration model serializer])
    path = migrations.first

    commit_generated_files
    migrate(environment: "test")

    destroy("model", remove_migrations: true)

    refute File.exist?(path)
  end

  def test_uncommitted_pending_migration_is_removed_automatically
    resource(parts: %i[migration model serializer])
    path = migrations.first

    destroy("model")

    refute File.exist?(path)
  end

  def test_cli_remove_migrations_removes_committed_pending_migration
    resource(parts: %i[migration model serializer])
    path = migrations.first

    commit_generated_files
    migrate(environment: "test")

    output, error, status = in_app(
      "bundle",
      "exec",
      "gemstack",
      "d",
      "model",
      "Post",
      "--yes",
      "--remove-migrations",
      "--skip-contract"
    )

    assert status.success?, output + error
    refute File.exist?(path)
  end

  def test_no_git_repository_preserves_pending_migrations
    FileUtils.remove_entry("#{@root}/.git")
    resource
    destroy
    assert_equal 1, migrations.size
    assert_includes @output.string, "Git state is unknown"
  end

  def test_explicit_removal_never_deletes_applied_migrations
    resource
    migrate
    destroy(remove_migrations: true, force: true)
    assert_equal 1, migrations.size
    migrate
  end

  def test_explicit_removal_with_unknown_database_state_preserves_migrations
    resource
    write("config/app.rb", "raise 'database unavailable'\n")
    destroy(remove_migrations: true)
    assert_equal 1, migrations.size
  end

  def test_explicit_removal_dry_run_preserves_committed_migration
    resource
    commit_generated_files
    before = snapshot
    destroy(remove_migrations: true, dry_run: true)
    assert_equal before, snapshot
  end

  def test_commit_during_confirmation_prevents_automatic_migration_removal
    resource
    error = assert_raises(Thor::Error) do
      destroy do
        commit_generated_files
        true
      end
    end
    assert_includes error.message, "Migration Git state changed"
    assert exists?("app/models/post.rb")
    assert_equal 1, migrations.size
  end
end

class DestroyMigrationTest < Minitest::Test
  include DestroyMigrationSupport

  def test_pending_destroy_regenerate_and_migrate
    resource
    original = migrations.first
    destroy
    refute File.exist?(original)
    assert_empty Manifest.new(@root).files
    resource
    assert_equal 1, migrations.size
    migrate
    assert_equal "true", app_eval("puts GemStack.db.table_exists?(:posts)")
  end

  def test_applied_destroy_regenerate_and_migrate_preserves_history_and_data
    resource
    migrate
    app_eval('GemStack.db[:posts].insert(title: "Keep me", created_at: Time.now, updated_at: Time.now)')
    original = migrations.to_h { |path| [path, File.binread(path)] }
    destroy
    assert_includes @output.string, "already applied"
    assert_includes @output.string, "db:rollback"
    assert_includes @output.string, "drops the table"
    resource(fields: %w[title:string description:text:optional])
    assert_includes @output.string, "gemstack g migration AddDescriptionToPosts description:text:optional"
    GemStack::CLI::MigrationGenerator.new("AddDescriptionToPosts", ["description:text:optional"],
                                          root: @root, output: @output).run
    migrate
    assert_equal(original, migrations.to_h { |path| [path, File.binread(path)] })
    assert_equal "Keep me", app_eval("puts GemStack.db[:posts].get(:title)")
    assert_equal "true", app_eval("puts GemStack.db.schema(:posts).to_h.key?(:description)")
    assert_includes @output.string, "use a new migration for schema changes"
  end

  def test_rolled_back_migration_can_be_removed_then_regenerated
    resource
    migrate
    destroy
    app_eval("GemStack::DB::Migrator.new.rollback")
    destroy
    assert_empty migrations
    resource
    migrate
    assert_equal "true", app_eval("puts GemStack.db.table_exists?(:posts)")
  end

  def test_dry_run_never_creates_a_missing_database
    resource
    before = snapshot
    destroy(dry_run: true)
    assert_equal before, snapshot
    refute exists?("db/development.sqlite3")
  end

  def test_unknown_database_state_keeps_migration_and_explains_it
    resource
    write("config/app.rb", "raise 'database unavailable'\n")
    original = migrations.first
    destroy
    assert File.exist?(original)
    refute exists?("app/models/post.rb")
    assert_includes @output.string, "database state unknown"
  end

  def test_dry_run_does_not_write_a_missing_lockfile
    resource
    File.delete("#{@root}/Gemfile.lock")
    before = snapshot
    destroy(dry_run: true)
    assert_equal before, snapshot
    assert_includes @output.string, "database state unknown"
  end

  def test_dry_run_preserves_an_existing_database
    resource
    migrate
    app_eval('GemStack.db[:posts].insert(title: "Keep me", created_at: Time.now, updated_at: Time.now)')
    before = persistent_files
    destroy(dry_run: true)
    assert_equal before, persistent_files
    assert_equal "Keep me", app_eval("puts GemStack.db[:posts].get(:title)")
  end

  # SQLite manages WAL/shared-memory sidecars even for read-only connections.
  def persistent_files
    snapshot.reject { |path, _| path.end_with?(".sqlite3-wal", ".sqlite3-shm") }
            .transform_values { |content| Digest::SHA256.hexdigest(content) }
  end

  def test_modified_pending_migration_requires_force
    resource
    path = migrations.first
    File.write(path, "#{File.read(path)}\n# customized\n")
    before = snapshot
    assert_raises(Thor::Error) { destroy }
    assert_equal before, snapshot
    destroy(force: true)
    refute File.exist?(path)
  end

  def test_applied_migration_is_preserved_even_with_force
    resource
    migrate
    path = migrations.first
    File.write(path, "#{File.read(path)}\n# customized\n")
    destroy(force: true)
    assert File.exist?(path)
  end

  def test_migration_applied_during_confirmation_prevents_removal
    resource
    error = assert_raises(Thor::Error) do
      destroy do
        migrate
        true
      end
    end
    assert_includes error.message, "Migration state changed"
    assert exists?("app/models/post.rb")
    assert_equal 1, migrations.size
  end

  def test_selected_environment_controls_migration_status
    resource
    migrate
    development = GemStack::CLI::MigrationStatus.new(@root, environment: "development")
    testing = GemStack::CLI::MigrationStatus.new(@root, environment: "test")
    assert_equal migrations.map { |path| File.basename(path) }, development.applied
    assert_empty testing.applied
  end

  def test_cli_alias_removes_pending_migration
    resource
    output, error, status = in_app("bundle", "exec", "gemstack", "d", "resource", "Post", "--yes", "--skip-contract")
    assert status.success?, output + error
    assert_empty migrations
    refute exists?("app/models/post.rb")
  end
end

class DestroyGeneratorTest < Minitest::Test
  include DestroyTestSupport

  def test_resource_removes_its_code_and_route_but_keeps_other_resources_and_shared_files
    resource
    resource("Comment")
    before = snapshot
    removed = destroy

    assert_predicate removed, :changed?
    %w[app/models/post.rb app/serializers/post_serializer.rb app/controllers/posts_controller.rb
       test/models/post_test.rb test/controllers/posts_controller_test.rb frontend/app/posts/page.tsx
       frontend/app/posts/[id]/edit/page.tsx frontend/components/posts/PostForm.tsx
       frontend/lib/queries/posts.ts].each { |path| refute exists?(path), path }
    %w[app/models/application_model.rb app/serializers/application_serializer.rb frontend/lib/format.ts
       app/models/comment.rb frontend/app/comments/page.tsx].each { |path| assert_equal before[path], read(path).b }
    refute_includes read("config/routes.rb"), "resources :posts"
    assert_includes read("config/routes.rb"), "resources :comments"
    assert_includes read("config/routes.rb"), "→"
    migrations = before.keys.grep(%r{\Adb/migrations/})
    migrations.each { |path| assert_equal before[path], read(path).b }
  end

  def test_model_only_removal_and_repeat_execution
    resource(parts: %i[migration model serializer])
    assert_predicate destroy("model"), :changed?
    after = snapshot
    refute_predicate destroy("model"), :changed?
    assert_equal after, snapshot
    assert_equal 1, Dir.glob("#{@root}/db/migrations/*.rb").size
  end

  def test_dry_run_preserves_every_byte_and_does_not_ask_for_confirmation
    resource
    before = snapshot
    removed = destroy(dry_run: true) { flunk "dry run must not prompt" }
    refute_predicate removed, :changed?
    assert_equal before, snapshot
    assert_includes @output.string, "Dry run"
    assert_includes @output.string, "remove"
  end

  def test_cancel_preserves_every_byte
    resource
    before = snapshot
    refute_predicate destroy { false }, :changed?
    assert_equal before, snapshot
  end

  def test_modified_file_blocks_the_entire_operation
    resource
    write("frontend/components/posts/PostForm.tsx", "// custom form\n")
    before = snapshot
    error = assert_raises(Thor::Error) { destroy }
    assert_includes error.message, "Modified file"
    assert_equal before, snapshot
    assert_predicate destroy(force: true), :changed?
    refute exists?("frontend/components/posts/PostForm.tsx")
  end

  def test_modified_route_is_never_removed_even_with_force
    resource
    write("config/routes.rb", read("config/routes.rb").sub("resources :posts", "resources :posts, only: [:index]"))
    before = snapshot
    error = assert_raises(Thor::Error) { destroy(force: true) }
    assert_includes error.message, "route was edited"
    assert_equal before, snapshot
  end

  def test_duplicate_route_is_ambiguous
    resource
    write("config/routes.rb", read("config/routes.rb").sub("  resources :posts\n", "  resources :posts\n  resources :posts\n"))
    before = snapshot
    assert_raises(Thor::Error) { destroy }
    assert_equal before, snapshot
  end

  def test_controller_removal_including_namespaces_and_custom_actions
    controller("Admin::ReportsController", %w[index publish])
    controller("Status", %w[show])
    destroy("controller", "Admin::ReportsController")
    refute exists?("app/controllers/admin/reports_controller.rb")
    refute exists?("test/controllers/admin/reports_controller_test.rb")
    refute_includes read("config/routes.rb"), "admin/reports#"
    assert_includes read("config/routes.rb"), "status#show"
  end

  def test_controller_can_be_removed_from_a_generated_resource
    resource
    destroy("controller", "Posts")
    assert exists?("app/models/post.rb")
    refute exists?("app/controllers/posts_controller.rb")
    refute_includes read("config/routes.rb"), "resources :posts"
  end

  def test_model_removal_refuses_remaining_controller_and_association_dependencies
    resource
    before = snapshot
    error = assert_raises(Thor::Error) { destroy("model") }
    assert_includes error.message, "app/controllers/posts_controller.rb"
    assert_equal before, snapshot

    write("app/models/comment.rb", "class Comment < ApplicationModel\n  belongs_to :post\nend\n")
    error = assert_raises(Thor::Error) { destroy(force: true) }
    assert_includes error.message, "app/models/comment.rb"
    assert exists?("app/models/post.rb")
  end

  def test_comments_and_strings_are_not_constant_dependencies
    resource
    write("app/models/note.rb", "# Post\nclass Note < ApplicationModel\n  LABEL = 'Post'\nend\n")
    assert_predicate destroy, :changed?
  end

  def test_preexisting_files_are_not_claimed_even_with_generator_force
    write("app/models/post.rb", "# an existing model\n")
    resource(parts: %i[model serializer], force: true)
    model = read("app/models/post.rb")
    assert_predicate destroy("model"), :changed?
    assert_equal model, read("app/models/post.rb")
  end

  def test_regeneration_keeps_original_hash_for_modified_skipped_files
    resource(parts: %i[model serializer])
    write("app/models/post.rb", "# customized\n")
    resource(parts: %i[model serializer])
    error = assert_raises(Thor::Error) { destroy("model") }
    assert_includes error.message, "Modified file: app/models/post.rb"
  end

  def test_frontend_only_removal_keeps_the_existing_model
    write("app/models/post.rb", "class Post < ApplicationModel; end\n")
    resource(parts: [:frontend])
    destroy
    assert exists?("app/models/post.rb")
    refute exists?("frontend/app/posts/page.tsx")
  end

  def test_custom_template_is_tracked_by_its_actual_generated_content
    write("lib/templates/gemstack/resource/model/app/models/%file_name%.rb.tt", "# custom <%= class_name %>\n")
    resource(parts: [:model])
    assert_equal "# custom Post\n", read("app/models/post.rb")
    destroy("model")
    refute exists?("app/models/post.rb")
    assert exists?("lib/templates/gemstack/resource/model/app/models/%file_name%.rb.tt")
  end

  def test_legacy_untracked_files_are_preserved
    write("app/models/post.rb", "# legacy model\n")
    before = snapshot
    refute_predicate destroy("model", force: true), :changed?
    assert_equal before, snapshot
    assert_includes @output.string, "manual removal"
  end

  def test_missing_tracked_file_is_forgotten
    resource(parts: [:model])
    File.delete("#{@root}/app/models/post.rb")
    assert_predicate destroy("model"), :changed?
    assert_empty Manifest.new(@root).files
  end
end

class DestroySafetyTest < Minitest::Test
  include DestroyTestSupport

  def test_invalid_manifest_prevents_changes
    resource
    write(Manifest::PATH, "{invalid")
    before = snapshot
    assert_raises(Thor::Error) { destroy }
    assert_equal before, snapshot
  end

  def test_unsupported_manifest_version_prevents_changes
    resource
    data = JSON.parse(read(Manifest::PATH))
    data["version"] = 99
    write(Manifest::PATH, JSON.generate(data))
    assert_raises(Thor::Error) { destroy }
    assert exists?("app/models/post.rb")
  end

  def test_path_traversal_is_refused
    resource
    data = JSON.parse(read(Manifest::PATH))
    data["files"]["app/../../outside.rb"] = data["files"].fetch("app/models/post.rb")
    write(Manifest::PATH, JSON.generate(data))
    before = snapshot
    assert_raises(Thor::Error) { destroy(force: true) }
    assert_equal before, snapshot
  end

  def test_symlinked_file_is_refused
    resource
    path = "#{@root}/app/models/post.rb"
    File.delete(path)
    File.symlink("#{@root}/app/models/application_model.rb", path)
    before = snapshot
    assert_raises(Thor::Error) { destroy(force: true) }
    assert_equal before, snapshot
  end

  def test_symlinked_parent_is_refused
    resource
    File.rename("#{@root}/frontend/app/posts", "#{@root}/frontend/app/saved-posts")
    File.symlink("#{@root}/frontend/app/saved-posts", "#{@root}/frontend/app/posts")
    assert_raises(Thor::Error) { destroy(force: true) }
    assert exists?("frontend/app/saved-posts/page.tsx")
    assert exists?("app/models/post.rb")
  end

  def test_symlinked_manifest_is_refused
    resource
    File.rename("#{@root}/.gemstack", "#{@root}/saved-manifest")
    File.symlink("#{@root}/saved-manifest", "#{@root}/.gemstack")
    assert_raises(Thor::Error) { destroy(force: true) }
    assert exists?("app/models/post.rb")
  end

  def test_shared_files_cannot_be_removed_via_manifest
    resource
    data = JSON.parse(read(Manifest::PATH))
    data["files"]["frontend/lib/format.ts"] = data["files"].fetch("app/models/post.rb")
    write(Manifest::PATH, JSON.generate(data))
    assert_raises(Thor::Error) { destroy(force: true) }
    assert exists?("frontend/lib/format.ts")
    assert exists?("app/models/post.rb")
  end

  def test_file_changes_during_confirmation_abort_before_removal
    resource
    assert_raises(Thor::Error) do
      destroy do
        write("app/models/post.rb", "# changed during confirmation\n")
        true
      end
    end
    assert exists?("app/controllers/posts_controller.rb")
    assert_includes read("config/routes.rb"), "resources :posts"
  end

  def test_route_changes_during_confirmation_abort_before_removal
    resource
    assert_raises(Thor::Error) do
      destroy do
        write("config/routes.rb", "#{read("config/routes.rb")}# edited\n")
        true
      end
    end
    assert exists?("app/models/post.rb")
  end

  def test_invalid_arguments
    [[nil, nil], ["job", "MailJob"], ["model", nil], ["model", "../Post"],
     ["controller", "../../Reports"]].each do |kind, name|
      assert_raises(Thor::Error) { destroy(kind, name) }
    end
  end

  def test_untracked_custom_route_blocks_controller_removal
    resource
    write("config/routes.rb", read("config/routes.rb").sub("GemStack.routes do\n", "GemStack.routes do\n  get '/featured', to: 'posts#index'\n"))
    before = snapshot
    error = assert_raises(Thor::Error) { destroy(force: true) }
    assert_includes error.message, "Remaining route to posts"
    assert_equal before, snapshot
  end

  def test_preexisting_resource_route_blocks_controller_removal
    write("config/routes.rb", "GemStack.routes do\n  resources :posts\nend\n")
    resource
    before = snapshot
    assert_raises(Thor::Error) { destroy }
    assert_equal before, snapshot
  end

  def test_changed_manifest_during_confirmation_aborts_before_removal
    resource
    assert_raises(Thor::Error) do
      destroy do
        write(Manifest::PATH, "#{read(Manifest::PATH)}\n")
        true
      end
    end
    assert exists?("app/models/post.rb")
    assert_includes read("config/routes.rb"), "resources :posts"
  end

  def test_cli_alias_and_dry_run_and_confirmation
    write("Gemfile", "")
    write("config/app.rb", "")
    resource(parts: %i[model serializer])
    before = snapshot
    Dir.chdir(@root) do
      capture_io { GemStack::CLI.start(%w[d model Post --dry-run --skip-contract]) }
      assert_equal before, snapshot
      cli = GemStack::CLI.new
      cli.options = { skip_contract: true }
      assert_raises(Thor::Error) { capture_io { cli.destroy("model", "Post") } } unless $stdin.tty?
      assert_equal before, snapshot
      capture_io { GemStack::CLI.start(%w[destroy model Post --yes --skip-contract]) }
    end
    refute exists?("app/models/post.rb")
  end
end
