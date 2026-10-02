# frozen_string_literal: true

require "test_helper"

class AppGeneratorTest < Minitest::Test
  def generate(name = "shop", **)
    @tmp = Dir.mktmpdir
    # Ensure consistent version detection by creating .tool-versions file
    File.write(File.join(@tmp, ".tool-versions"), "ruby #{RUBY_VERSION}\nnodejs 22.11.0\n")
    @out = StringIO.new
    Dir.chdir(@tmp) do
      GemStack::CLI::AppGenerator.new(name, { skip_install: true, skip_git: true, ** }, output: @out).run
    end
    File.join(@tmp, File.basename(name))
  end

  def teardown
    FileUtils.rm_rf(@tmp) if @tmp
  end

  def files(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject do |f|
      File.directory?(File.join(root, f))
    end.sort
  end

  def test_generates_backend_and_frontend
    root = generate

    expected = %w[
      .env.example .gitignore .node-version .nvmrc .ruby-version .tool-versions Gemfile README.md
      app/controllers/application_controller.rb
      app/jobs/application_job.rb app/mailers/application_mailer.rb app/mailers/templates/.keep
      app/models/application_model.rb app/serializers/application_serializer.rb bin/gemstack bin/gsk config.ru
      config/app.rb config/database.yml config/environments/development.rb config/environments/production.rb
      config/environments/test.rb config/puma.rb config/routes.rb db/migrations/.keep db/seeds.rb
      frontend/app/globals.css frontend/app/layout.tsx frontend/app/page.module.css frontend/app/page.tsx
      frontend/app/providers.tsx
      frontend/lib/gemstack/client.ts frontend/next-env.d.ts frontend/next.config.ts frontend/package.json
      frontend/tsconfig.json test/health_test.rb test/test_helper.rb
    ]

    assert_equal expected, files(root)
    assert File.executable?(File.join(root, "bin/gemstack"))
    assert File.executable?(File.join(root, "bin/gsk"))
  end

  def test_no_business_resources
    root = generate

    assert_equal ["application_controller.rb"], Dir.children(File.join(root, "app/controllers"))
    assert_match(/GemStack\.routes do\nend/, File.read(File.join(root, "config/routes.rb")))
    assert_equal ["application_model.rb"], Dir.children(File.join(root, "app/models")), "only the base class"
    assert_equal ["application_job.rb"], Dir.children(File.join(root, "app/jobs"))
  end

  def test_ruby_version_is_pinned
    root = generate

    node = GemStack::Dev::Toolchain.pinned_node_version

    assert_equal "#{RUBY_VERSION}\n", File.read(File.join(root, ".ruby-version"))
    assert_equal "ruby #{RUBY_VERSION}\nnodejs #{node}\n", File.read(File.join(root, ".tool-versions"))
    assert_equal "#{node}\n", File.read(File.join(root, ".node-version"))
    assert_equal "#{node}\n", File.read(File.join(root, ".nvmrc"))
  end

  def test_templates_are_rendered
    root = generate("my-shop")

    assert_includes File.read(File.join(root, "config/app.rb")), %(config.name = "my-shop")
    assert_includes File.read(File.join(root, "frontend/app/layout.tsx")), %(title: "MyShop")
    assert_equal "my-shop-frontend", JSON.parse(File.read(File.join(root, "frontend/package.json")))["name"]
    refute_includes File.read(File.join(root, "frontend/app/page.tsx")), "<%"
  end

  def test_sqlite_is_the_default_database
    require "gemstack/db" # only to check the generated file parses (the CLI itself never loads it)
    root = generate("my-shop")
    yml = File.read(File.join(root, "config/database.yml"))

    assert_includes yml, "adapter: sqlite3"
    assert_includes yml, "database: db/development.sqlite3"
    assert_includes yml, %(<%= ENV.fetch("GEMSTACK_MAX_THREADS", 5) %>), "runtime ERB is kept"
    assert_match(/^gem "sqlite3", "~> 2\.0"/, File.read(File.join(root, "Gemfile")))
    assert_includes File.read(File.join(root, ".gitignore")), "/db/*.sqlite3\n"
    settings = GemStack::DB::Configuration.from_hash(
      YAML.safe_load(ERB.new(yml).result, aliases: true)["test"], root: root
    )

    assert_equal({ adapter: "sqlite", database: File.join(root, "db/test.sqlite3"), max_connections: 5 }, settings)
  end

  def test_database_choices
    { "postgresql" => ["adapter: postgresql", %(gem "pg")], "mysql" => ["adapter: mysql2", %(gem "mysql2")],
      "trilogy" => ["adapter: trilogy", %(gem "trilogy")] }.each do |choice, (adapter, gem_line)|
      root = generate("my-shop", database: choice)

      assert_includes File.read(File.join(root, "config/database.yml")), adapter
      assert_includes File.read(File.join(root, "config/database.yml")), "database: my_shop_test"
      assert_includes File.read(File.join(root, "Gemfile")), gem_line
      teardown
    end
    assert_raises(Thor::Error) { generate("x", database: "oracle") }
  end

  def test_skip_database_has_no_database_yml
    root = generate(skip_database: true)

    refute File.exist?(File.join(root, "config/database.yml"))
    refute_includes File.read(File.join(root, "Gemfile")), "sqlite3"
  end

  def test_gemfile_uses_checkout_when_available
    root = generate
    gemfile = File.read(File.join(root, "Gemfile"))

    assert_includes gemfile, %(path "#{GemStack::CLI::AppGenerator::CHECKOUT}" do)
  end

  def test_gemfile_uses_version_without_checkout
    generator = GemStack::CLI::AppGenerator.new("x", {}, output: StringIO.new)
    generator.instance_variable_set(:@gemstack_path, nil)
    source = File.read(File.join(GemStack::CLI::Generator::TEMPLATES, "app/Gemfile.tt"))

    assert_includes generator.render(source), %(gem "gemstack", "~> #{GemStack::VERSION}")
  end

  def test_skip_frontend
    root = generate(skip_frontend: true)

    refute Dir.exist?(File.join(root, "frontend"))
    refute File.exist?(File.join(root, ".nvmrc")), "no Node.js pin without a frontend"
    assert_equal "ruby #{RUBY_VERSION}\n", File.read(File.join(root, ".tool-versions"))
  end

  def test_database_by_default_and_skip_database
    root = generate

    app_rb = File.read(File.join(root, "config/app.rb"))

    assert_includes app_rb, %(require "gemstack"\nrequire "gemstack/db")
    assert_includes app_rb, %(require "gemstack/jobs")
    assert_includes app_rb, %(require "gemstack/mail")
    assert_includes app_rb, %(# require "gemstack/storage")
    refute_match(/gem "gemstack-/, File.read(File.join(root, "Gemfile")), "one gem since 0.3.0")
    assert_includes File.read(File.join(root, "bin/gemstack")), %(Gem.bin_path("gemstack-cli", "gemstack"))
    assert_includes File.read(File.join(root, "test/test_helper.rb")), "GemStack::DB::Testing.prepare!"
    assert_includes File.read(File.join(root, "test/test_helper.rb")), "GemStack::TestCase.include GemStack::Jobs::Testing"
    assert_empty Dir.glob(File.join(root, "db/migrations/*.rb")), "no tables until the app uses jobs"
    FileUtils.rm_rf(@tmp)

    root = generate(skip_database: true)

    refute_includes File.read(File.join(root, "config/app.rb")), %(require "gemstack/db")
    refute_includes File.read(File.join(root, "test/test_helper.rb")), "DB::Testing"
    refute Dir.exist?(File.join(root, "db"))
  end

  def test_rejects_invalid_names_and_non_empty_directories
    assert_raises(Thor::Error) { generate("Bad Name") }
    root = generate
    assert_raises(Thor::Error) do
      GemStack::CLI::AppGenerator.new(root, { skip_install: true }, output: StringIO.new).run
    end
  end
end

class ControllerGeneratorTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p("#{@root}/config")
    File.write("#{@root}/config/routes.rb", "# comment\nGemStack.routes do\nend\n")
    @out = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def generate(name, actions = [], **)
    GemStack::CLI::ControllerGenerator.new(name, actions, root: @root, output: @out, **).run
  end

  def test_rest_and_custom_actions
    generate("Products", %w[index show create update destroy publish])
    routes = File.read("#{@root}/config/routes.rb")

    assert_includes routes, %(  get "/products", to: "products#index")
    assert_includes routes, %(  get "/products/:id", to: "products#show")
    assert_includes routes, %(  post "/products", to: "products#create")
    assert_includes routes, %(  patch "/products/:id", to: "products#update")
    assert_includes routes, %(  delete "/products/:id", to: "products#destroy")
    assert_includes routes, %(  get "/products/publish", to: "products#publish")

    controller = File.read("#{@root}/app/controllers/products_controller.rb")

    assert_includes controller, "class ProductsController < ApplicationController"
    assert_includes controller, "def publish"
    test = File.read("#{@root}/test/controllers/products_controller_test.rb")

    assert_includes test, %(require_relative "../test_helper")
    assert_includes test, %(delete_json "/api/products/1")
  end

  def test_namespaced_and_controller_suffix
    generate("Admin::InventoryItemsController", %w[index])

    assert File.file?("#{@root}/app/controllers/admin/inventory_items_controller.rb")
    assert_includes File.read("#{@root}/config/routes.rb"),
                    %(get "/admin/inventory-items", to: "admin/inventory_items#index")
    assert_includes File.read("#{@root}/test/controllers/admin/inventory_items_controller_test.rb"),
                    %(require_relative "../../test_helper")
  end

  def test_defaults_to_index
    generate("status")

    assert_includes File.read("#{@root}/config/routes.rb"), %(get "/status", to: "status#index")
  end

  def test_running_twice_is_idempotent
    generate("Products", %w[index])
    before = File.read("#{@root}/config/routes.rb")
    generate("Products", %w[index])

    assert_equal before, File.read("#{@root}/config/routes.rb")
    assert_includes @out.string, "identical"
  end

  def test_does_not_overwrite_changed_files
    generate("Products", %w[index])
    File.write("#{@root}/app/controllers/products_controller.rb", "# mine")
    generate("Products", %w[index])

    assert_equal "# mine", File.read("#{@root}/app/controllers/products_controller.rb")
    assert_includes @out.string, "not overwritten"
  end

  def test_app_template_overrides
    custom = "#{@root}/lib/templates/gemstack/controller/app/controllers/%file_name%_controller.rb.tt"
    FileUtils.mkdir_p(File.dirname(custom))
    File.write(custom, "# custom <%= class_name %>\n")
    generate("Products")

    assert_equal "# custom ProductsController\n", File.read("#{@root}/app/controllers/products_controller.rb")
  end

  def test_invalid_actions
    assert_raises(Thor::Error) { generate("Products", ["bad-action!"]) }
  end
end

class ProjectTest < Minitest::Test
  def test_finds_root_from_subdirectories
    Dir.mktmpdir do |dir|
      root = File.realpath(dir)
      FileUtils.mkdir_p("#{root}/config")
      FileUtils.mkdir_p("#{root}/app/controllers")
      File.write("#{root}/config/app.rb", "")
      File.write("#{root}/Gemfile", "")

      assert_equal root, GemStack::CLI::Project.root("#{root}/app/controllers")
      assert_nil GemStack::CLI::Project.root("/")
    end
  end
end

class CLICommandsTest < Minitest::Test
  def run_cli(*args)
    out, = capture_io { GemStack::CLI.start(args) }
    out
  end

  def test_version
    assert_equal "GemStack #{GemStack::VERSION}\n", run_cli("version")
    assert_equal "GemStack #{GemStack::VERSION}\n", run_cli("--version")
  end

  def test_help_lists_core_commands
    help = run_cli("help")

    %w[new dev server routes console test generate version].each { |cmd| assert_includes help, "gemstack #{cmd}" }
  end
end
