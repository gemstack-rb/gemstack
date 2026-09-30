# frozen_string_literal: true

require "test_helper"

class ResourceSpecTest < Minitest::Test
  Spec = GemStack::CLI::ResourceSpec

  def test_names
    spec = Spec.new("line_items", ["name"])

    assert_equal %w[LineItem line_item line_items LineItems line-items lineItems lineItem],
                 [spec.class_name, spec.file_name, spec.plural, spec.plural_class, spec.url_segment,
                  spec.client_name, spec.variable]
  end

  def test_fields
    spec = Spec.new("Product", %w[name price:decimal notes:text:optional sku:string:unique category:references
                                  active:boolean])
    by_name = spec.fields.to_h { |f| [f.name, f] }

    assert_equal "string", by_name["name"].type
    assert_predicate by_name["name"], :required?
    refute_predicate by_name["notes"], :required?
    refute_predicate by_name["active"], :required?
    assert by_name["sku"].unique
    assert_equal "category_id", by_name["category"].column
    assert by_name["category"].index
  end

  def test_invalid_input
    assert_raises(Thor::Error) { Spec.new("Product", ["price:money"]) }
    assert_raises(Thor::Error) { Spec.new("Product", ["price:decimal:big"]) }
    assert_raises(Thor::Error) { Spec.new("Product", %w[name name:text]) }
    assert_raises(Thor::Error) { Spec.new("Admin::Product", ["name"]) }
    assert_raises(Thor::Error) { Spec.new("Product", ["name"], actions: %w[index publish]) }
  end
end

class ResourceGeneratorTest < Minitest::Test
  FIELDS = %w[name price:decimal description:text:optional sku:string:unique category:references active:boolean
              released_on:date:optional].freeze

  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p("#{@root}/config")
    File.write("#{@root}/config/routes.rb", "GemStack.routes do\nend\n")
    @out = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def generate(fields = FIELDS, name: "Product", actions: GemStack::CLI::ResourceSpec::REST_ACTIONS, **)
    spec = GemStack::CLI::ResourceSpec.new(name, fields, actions: actions)
    GemStack::CLI::ResourceGenerator.new(spec, root: @root, output: @out, timestamp: "20260928120000", **).run
  end

  def read(path) = File.read(File.join(@root, path))
  def files = Dir.glob("**/*", base: @root).reject { |f| File.directory?(File.join(@root, f)) }.sort

  def test_full_slice
    generate

    assert_equal %w[
      app/controllers/products_controller.rb app/models/application_model.rb app/models/product.rb
      app/serializers/application_serializer.rb app/serializers/product_serializer.rb
      config/routes.rb db/migrations/20260928120000_create_products.rb
      frontend/app/products/[id]/edit/page.tsx frontend/app/products/[id]/page.tsx frontend/app/products/new/page.tsx
      frontend/app/products/page.tsx frontend/components/products/ProductCard.tsx
      frontend/components/products/ProductForm.tsx frontend/components/products/ProductTable.tsx
      frontend/lib/format.ts frontend/lib/queries/products.ts
      test/controllers/products_controller_test.rb test/models/product_test.rb
    ], files
    assert_includes read("config/routes.rb"), "  resources :products\n"
    assert_includes read("app/models/product.rb"), "class Product < ApplicationModel"
    assert_includes read("app/serializers/product_serializer.rb"), "class ProductSerializer < ApplicationSerializer"
  end

  def test_existing_base_classes_are_kept
    FileUtils.mkdir_p("#{@root}/app/models")
    File.write("#{@root}/app/models/application_model.rb", "# mine\n")
    generate

    assert_equal "# mine\n", read("app/models/application_model.rb")
  end

  def test_migration
    generate
    migration = read("db/migrations/20260928120000_create_products.rb")

    assert_includes migration, "create_table(:products) do"
    assert_includes migration, "String :name, null: false"
    assert_includes migration, "BigDecimal :price, size: [12, 2], null: false"
    assert_includes migration, "String :description, text: true\n"
    assert_includes migration, "String :sku, null: false, unique: true"
    assert_includes migration, "foreign_key :category_id, :categories, type: :Bignum, null: false, on_delete: :restrict"
    assert_includes migration, "TrueClass :active, null: false, default: false"
    assert_includes migration, "Date :released_on\n"
    assert_includes migration, "index :category_id"
    assert_includes migration, "column :created_at, :timestamptz, null: false"
  end

  def test_model_serializer_controller
    generate

    model = read("app/models/product.rb")

    assert_includes model, "field :name, :string, null: false, size: 255"
    assert_includes model, "field :description, :text\n"
    assert_includes model, "field :category_id, :references, null: false"
    assert_includes model, "field :active, :boolean, null: false, default: false"
    assert_includes model, "validates :sku, uniqueness: true"
    assert_includes model, "belongs_to :category"
    assert_includes read("app/serializers/product_serializer.rb"),
                    "attributes :id, :name, :price, :description, :sku, :category_id, :active, :released_on, :created_at, :updated_at"
    controller = read("app/controllers/products_controller.rb")

    assert_includes controller, "returns :index, GemStack::Page[ProductSerializer]"
    assert_includes controller, "render paginate(Product.order(:id))"
    assert_includes controller, "accepts :create, with: Product.input_schema"
    assert_includes controller, "accepts :update, with: Product.input_schema, partial: true"
    assert_includes controller, "render Product.create(input), status: :created"
    assert_includes controller, "head :no_content"
  end

  def test_generated_ruby_is_valid_syntax
    generate
    Dir.glob("**/*.rb", base: @root).each do |file|
      assert system(RbConfig.ruby, "-c", File.join(@root, file), out: File::NULL), "#{file} has a syntax error"
    end
  end

  def test_tests_use_sample_data
    generate
    test = read("test/controllers/products_controller_test.rb")

    assert_includes test, "GemStack::DB::Testing.sample_payload(Product)"
    assert_includes test, %(assert_error 422, "validation_failed")
    assert_includes test, %(assert_equal ["is required"], json_body["errors"]["name"])
    assert_includes read("test/models/product_test.rb"), "def test_requires_category_id"
  end

  def test_frontend_form
    generate
    form = read("frontend/components/products/ProductForm.tsx")

    assert_includes form, "import type { Product, ProductInput } from \"@/lib/api/generated\";"
    assert_includes form, "price: record?.price ?? \"\","
    assert_includes form, "category_id: String(record?.category_id ?? \"\"),"
    assert_includes form, "active: record?.active ?? false,"
    assert_includes form, "description: values.description === \"\" ? null : values.description,"
    assert_includes form, "category_id: values.category_id === \"\" ? \"\" : Number(values.category_id),"
    assert_includes form,
                    %(<input id="price" name="price" type="text" inputMode="decimal" value={values.price} onChange={set("price")} required />)
    assert_includes form,
                    %(<input id="active" name="active" type="checkbox" checked={values.active} onChange={set("active")} />)
    refute_includes form, "<%"
  end

  def test_read_only_resource
    generate(%w[name], actions: %w[index show])

    assert_includes read("config/routes.rb"), "resources :products, only: %i[index show]"
    refute File.exist?(File.join(@root, "frontend/app/products/new/page.tsx"))
    refute File.exist?(File.join(@root, "frontend/components/products/ProductForm.tsx"))
    refute_includes read("app/controllers/products_controller.rb"), "accepts"
    refute_includes read("frontend/lib/queries/products.ts"), "useCreateProduct"
  end

  def test_api_only_and_frontend_only_parts
    generate(parts: %i[migration model serializer controller])

    refute Dir.exist?(File.join(@root, "frontend"))
    FileUtils.rm_rf(Dir.glob("#{@root}/{app,db,test}"))
    generate(parts: %i[frontend])

    refute Dir.exist?(File.join(@root, "app"))
    assert File.exist?(File.join(@root, "frontend/app/products/page.tsx"))
  end

  def test_skip_tests
    generate(tests: false)

    refute Dir.exist?(File.join(@root, "test"))
  end

  def test_routes_are_not_duplicated_and_files_not_overwritten
    generate
    File.write(File.join(@root, "app/models/product.rb"), "# mine\n")
    generate

    assert_equal 1, read("config/routes.rb").scan("resources :products").size
    assert_equal "# mine\n", read("app/models/product.rb")
  end

  def test_template_override
    custom = File.join(@root, "lib/templates/gemstack/resource/model/app/models/%file_name%.rb.tt")
    FileUtils.mkdir_p(File.dirname(custom))
    File.write(custom, "# custom <%= class_name %>\n")
    generate

    assert_equal "# custom Product\n", read("app/models/product.rb")
  end
end

class MigrationGeneratorTest < Minitest::Test
  def test_add_columns
    Dir.mktmpdir do |root|
      GemStack::CLI::MigrationGenerator.new("AddSkuToProducts", %w[sku:string:unique weight:decimal:optional],
                                            root: root, output: StringIO.new, timestamp: "20260101000000").run
      migration = File.read(File.join(root, "db/migrations/20260101000000_add_sku_to_products.rb"))

      assert_includes migration, "alter_table(:products) do"
      assert_includes migration, "add_column :sku, String, null: false, unique: true"
      assert_includes migration, "add_column :weight, BigDecimal, size: [12, 2]"
      assert system(RbConfig.ruby, "-c", File.join(root, "db/migrations/20260101000000_add_sku_to_products.rb"),
                    out: File::NULL)
    end
  end

  def test_empty_migration
    Dir.mktmpdir do |root|
      GemStack::CLI::MigrationGenerator.new("BackfillPrices", [], root: root, output: StringIO.new,
                                                                  timestamp: "20260101000000").run

      assert_includes File.read(File.join(root, "db/migrations/20260101000000_backfill_prices.rb")), "# create_table"
    end
  end
end

class JobGeneratorTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p("#{@root}/db/migrations")
    @out = StringIO.new
  end

  def teardown = FileUtils.rm_rf(@root)

  def generate(name, queue: nil) = GemStack::CLI::JobGenerator.new(name, queue: queue, root: @root, output: @out).run

  def test_job_test_and_one_time_migration
    generate("SendWelcomeEmail", queue: "mailers")
    job = File.read("#{@root}/app/jobs/send_welcome_email.rb")

    assert_includes job, "class SendWelcomeEmail < ApplicationJob"
    assert_includes job, "queue :mailers"
    assert_includes File.read("#{@root}/test/jobs/send_welcome_email_test.rb"), "assert_enqueued SendWelcomeEmail, args: [1]"
    migrations = Dir.glob("#{@root}/db/migrations/*_create_gemstack_jobs.rb")

    assert_equal 1, migrations.size
    assert_includes File.read(migrations.first), "create_table(:gemstack_jobs)"

    generate("ImportJob")

    assert File.exist?("#{@root}/app/jobs/import_job.rb")
    assert_equal 1, Dir.glob("#{@root}/db/migrations/*_create_gemstack_jobs.rb").size
    Dir.glob("#{@root}/**/*.rb").each { |f| assert system(RbConfig.ruby, "-c", f, out: File::NULL), f }
  end

  def test_invalid_names
    assert_raises(Thor::Error) { generate("send-email!") }
  end

  def test_names_clashing_with_ruby_constants_are_refused
    error = assert_raises(Thor::Error) { generate("Digest") }

    assert_includes error.message, "try DigestJob"
    assert_raises(Thor::Error) { GemStack::CLI::ResourceSpec.new("Set", ["name"]) }
    assert_raises(Thor::Error) { GemStack::CLI::ResourceSpec.new("Time", ["name"]) }
    generate("DigestJob") # fine
    GemStack::CLI::ResourceSpec.new("Page", ["title"]) # GemStack's own names are namespaced: allowed
    GemStack::CLI::ResourceSpec.new("Job", ["title"])
  end

  def test_migration_timestamps_are_unique
    time = Time.utc(2026, 1, 1, 12, 0, 0)
    File.write("#{@root}/db/migrations/20260101120000_a.rb", "")
    File.write("#{@root}/db/migrations/20260101120001_b.rb", "")

    assert_equal "20260101120002", GemStack::CLI::Generator.migration_timestamp(@root, time)
  end
end

class AddGeneratorTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(%W[#{@root}/test #{@root}/frontend #{@root}/config])
    File.write("#{@root}/test/test_helper.rb", %(require_relative "../config/app"\nrequire "gemstack/testing"\n))
    @out = StringIO.new
  end

  def teardown = FileUtils.rm_rf(@root)

  def add = GemStack::CLI::AddGenerator.new("realtime", root: @root, output: @out, install: false).run

  def test_realtime_in_a_checkout_app
    File.write("#{@root}/Gemfile", %(path "/x/gems" do\n  gem "gemstack"\n  gem "gemstack-jobs"\n  gem "gemstack-schema"\nend\ngem "puma"\n))
    add

    assert_includes File.read("#{@root}/Gemfile"),
                    %(  gem "gemstack-jobs"\n  gem "gemstack-realtime"\n  gem "gemstack-schema"\nend) # sorted
    assert File.exist?("#{@root}/config/channels.rb")
    assert File.exist?("#{@root}/frontend/lib/gemstack/realtime.ts")
    helper = File.read("#{@root}/test/test_helper.rb")

    assert_includes helper, %(require "gemstack/testing"\nrequire "gemstack/realtime/testing")
    assert_includes helper, "GemStack::TestCase.include GemStack::Realtime::Testing"
    add # idempotent

    assert_equal 1, File.read("#{@root}/Gemfile").scan("gemstack-realtime").size
    assert_equal 1, File.read("#{@root}/test/test_helper.rb").scan("Realtime::Testing\n").size
  end

  def test_realtime_in_a_versioned_app
    File.write("#{@root}/Gemfile", %(source "https://rubygems.org"\ngem "gemstack", "~> 0.1.0"\n))
    add

    assert_includes File.read("#{@root}/Gemfile"), %(gem "gemstack-realtime", "~> #{GemStack::VERSION}")
  end

  def test_unknown_feature
    assert_raises(Thor::Error) { GemStack::CLI::AddGenerator.new("teleport", root: @root) }
  end

  APP_RB = <<~RUBY
    require "bundler/setup"
    require "gemstack"
    require "gemstack/db"
    require "gemstack/jobs"
    # require "gemstack/storage" # file uploads
  RUBY

  def auth_app(gemfile: %(path "/x/gems" do\n  gem "gemstack"\nend\n), app_rb: APP_RB)
    FileUtils.mkdir_p(%W[#{@root}/app/controllers #{@root}/db/migrations])
    File.write("#{@root}/Gemfile", gemfile)
    File.write("#{@root}/config/app.rb", app_rb)
    File.write("#{@root}/app/controllers/application_controller.rb",
               "# Shared.\nclass ApplicationController < GemStack::Controller\nend\n")
    File.write("#{@root}/config/routes.rb", "GemStack.routes do\nend\n")
    File.write("#{@root}/.env.example", "# PORT=3000\n")
  end

  def add_auth = GemStack::CLI::AddGenerator.new("auth", root: @root, output: @out, install: false).run

  def test_auth
    auth_app
    add_auth

    assert_includes File.read("#{@root}/Gemfile"), %(  gem "gemstack"\n  gem "gemstack-auth"\nend)
    assert_includes File.read("#{@root}/config/app.rb"), %(require "gemstack"\nrequire "gemstack/mail"\n),
                    "mail switched on in config/app.rb"
    assert_includes File.read("#{@root}/app/controllers/application_controller.rb"),
                    "class ApplicationController < GemStack::Controller\n  include GemStack::Auth::Controller\n"
    routes = File.read("#{@root}/config/routes.rb")
    assert_includes routes, %(GemStack.routes do\n  # Authentication)
    assert_includes routes, %(  post "/auth/login", to: "sessions#create"\n)
    migrations = Dir.children("#{@root}/db/migrations").sort
    assert_equal 2, migrations.size
    assert_match(/\A\d{14}_create_gemstack_jobs\.rb\z/, migrations[0])
    assert_match(/\A\d{14}_create_auth_tables\.rb\z/, migrations[1])
    %w[app/models/user.rb app/controllers/sessions_controller.rb app/mailers/auth_mailer.rb
       app/mailers/templates/auth_mailer/password_reset.html.erb app/policies/application_policy.rb
       test/controllers/auth_test.rb frontend/lib/auth.ts frontend/app/login/page.tsx].each do |file|
      assert File.exist?("#{@root}/#{file}"), "#{file} was not generated"
    end
    assert_includes File.read("#{@root}/.env.example"), "SMTP_URL"
    assert_includes File.read("#{@root}/test/test_helper.rb"), "GemStack::TestCase.include GemStack::Auth::Testing"

    add_auth # idempotent

    assert_equal 2, Dir.children("#{@root}/db/migrations").size
    assert_equal 1, File.read("#{@root}/config/routes.rb").scan("/auth/login").size
    assert_equal 1, File.read("#{@root}/app/controllers/application_controller.rb").scan("Auth::Controller").size
  end

  def test_auth_needs_a_database
    File.write("#{@root}/Gemfile", %(gem "gemstack", "~> 0.3.0"\n))
    File.write("#{@root}/config/app.rb", %(require "gemstack"\n))
    error = assert_raises(Thor::Error) { add_auth }

    assert_includes error.message, "created without one"
  end

  def test_auth_in_an_app_from_before_0_3
    auth_app(gemfile: %(gem "gemstack", "~> 0.2.5"\ngem "gemstack-db", "~> 0.2.5"\ngem "gemstack-jobs", "~> 0.2.5"\n),
             app_rb: %(require "bundler/setup"\nrequire "gemstack"\n))
    add_auth

    assert_includes File.read("#{@root}/Gemfile"), %(gem "gemstack-auth")
    app_rb = File.read("#{@root}/config/app.rb")

    assert_includes app_rb, %(require "gemstack/mail"), "the one module the old Gemfile didn't list"
    refute_includes app_rb, %(require "gemstack/db"), "db and jobs still come from the Gemfile lines"
  end

  def test_storage_uncomments_its_require
    auth_app
    GemStack::CLI::AddGenerator.new("storage", root: @root, output: @out, install: false).run
    app_rb = File.read("#{@root}/config/app.rb")

    assert_includes app_rb, %(require "gemstack/storage"\n)
    refute_includes app_rb, "# require \"gemstack/storage\""
    refute_includes File.read("#{@root}/Gemfile"), "gemstack-storage"
  end

  def test_auth_refuses_to_overwrite_a_user_model
    auth_app
    FileUtils.mkdir_p("#{@root}/app/models")
    File.write("#{@root}/app/models/user.rb", "class User < GemStack::Model\nend\n")

    assert_raises(Thor::Error) { add_auth }
  end

  def test_storage_with_auth
    auth_app
    File.write("#{@root}/.gitignore", "/tmp/\n")
    add_auth
    GemStack::CLI::AddGenerator.new("storage", root: @root, output: @out, install: false).run

    controller = File.read("#{@root}/app/controllers/uploads_controller.rb")
    assert_includes controller, "  before :require_login\n"
    assert_includes File.read("#{@root}/test/controllers/uploads_test.rb"), "sign_in_as"
    assert_includes File.read("#{@root}/config/routes.rb"), %(post "/uploads", to: "uploads#create")
    assert_includes File.read("#{@root}/.gitignore"), "/storage/\n"
    assert File.exist?("#{@root}/frontend/lib/upload.ts")
    refute File.exist?("#{@root}/app/controllers/uploads_controller.rb.tt")
  end

  def test_storage_without_auth
    auth_app
    GemStack::CLI::AddGenerator.new("storage", root: @root, output: @out, install: false).run

    assert_includes File.read("#{@root}/app/controllers/uploads_controller.rb"), "  # before :require_login\n"
  end

  def test_policy_generator
    FileUtils.mkdir_p("#{@root}/app/policies")
    File.write("#{@root}/app/policies/application_policy.rb", "")
    GemStack::CLI::PolicyGenerator.new("Order", root: @root, output: @out).run
    policy = File.read("#{@root}/app/policies/order_policy.rb")

    assert_includes policy, "class OrderPolicy < ApplicationPolicy"
    assert_includes File.read("#{@root}/test/policies/order_policy_test.rb"), "class OrderPolicyTest < GemStack::TestCase"
  end
end

class DeployGeneratorTest < Minitest::Test
  def setup
    @root = File.join(Dir.mktmpdir, "my_shop")
    FileUtils.mkdir_p(%W[#{@root}/frontend #{@root}/app/jobs])
    File.write("#{@root}/frontend/package.json", "{}")
    File.write("#{@root}/.ruby-version", "4.0.7\n")
    File.write("#{@root}/.tool-versions", "ruby 4.0.7\nnodejs 22.11.0\n")
    @out = StringIO.new
  end

  def teardown = FileUtils.rm_rf(File.dirname(@root))

  def generate(gemfile)
    File.write("#{@root}/Gemfile", gemfile)
    GemStack::CLI::DeployGenerator.new(root: @root, output: @out).run
  end

  def test_full_stack_app
    File.write("#{@root}/app/jobs/digest.rb", "")
    generate(%(gem "gemstack", "~> 0.1.0"\ngem "gemstack-db"\ngem "gemstack-jobs"\ngem "gemstack-auth"\n))
    dockerfile = File.read("#{@root}/Dockerfile")
    compose = File.read("#{@root}/compose.yaml")

    assert_includes dockerfile, "ARG RUBY_VERSION=4.0.7"
    assert_includes dockerfile, "ARG NODE_VERSION=22"
    assert_includes dockerfile, "FROM node:${NODE_VERSION}-slim AS web"
    assert_includes dockerfile, "USER app"
    assert_includes compose, "name: my-shop"
    assert_includes compose, "  jobs:\n    image: my_shop-api"
    assert_includes compose, "SMTP_URL"
    assert_includes compose, "SECRET_KEY_BASE: ${SECRET_KEY_BASE:?"
    assert_includes File.read("#{@root}/Caddyfile"), "reverse_proxy web:3000"
    assert_includes File.read("#{@root}/Procfile"), "worker: bundle exec gemstack jobs"
    ignore = File.read("#{@root}/.dockerignore")

    assert_includes ignore, ".env\n"
    assert_includes ignore, "!.env.example"
    assert File.exist?("#{@root}/vendor/.keep")
  end

  def test_base_classes_alone_are_not_background_work
    FileUtils.rm_rf("#{@root}/app/jobs")
    FileUtils.mkdir_p(%W[#{@root}/app/jobs #{@root}/app/mailers])
    File.write("#{@root}/app/jobs/application_job.rb", "")
    File.write("#{@root}/app/mailers/application_mailer.rb", "")

    refute GemStack::CLI::Generator.background_work?(@root)
    File.write("#{@root}/app/jobs/digest.rb", "")

    assert GemStack::CLI::Generator.background_work?(@root)
  end

  def test_api_only_app_without_jobs
    FileUtils.rm_rf("#{@root}/frontend")
    generate(%(gem "gemstack", "~> 0.1.0"\n))

    refute_includes File.read("#{@root}/Dockerfile"), "AS web"
    refute_includes File.read("#{@root}/compose.yaml"), "  jobs:"
    refute_includes File.read("#{@root}/compose.yaml"), "SMTP_URL"
    refute_includes File.read("#{@root}/Caddyfile"), "web:3000"
    refute_includes File.read("#{@root}/Procfile"), "worker:"
  end

  def with_database_yml(adapter)
    FileUtils.mkdir_p("#{@root}/config")
    File.write("#{@root}/config/database.yml", "default: &default\n  adapter: #{adapter}\nproduction:\n  <<: *default\n")
  end

  def test_sqlite_app
    with_database_yml("sqlite3")
    generate(%(gem "gemstack"\ngem "gemstack-db"\ngem "gemstack-jobs"\ngem "gemstack-realtime"\ngem "gemstack-auth"\n))
    compose = File.read("#{@root}/compose.yaml")

    assert_includes compose, "DATABASE_URL: sqlite3:/data/production.sqlite3"
    assert_includes compose, "    volumes: [data:/data]"
    refute_includes compose, "image: postgres"
    assert_includes compose, "REDIS_URL: redis://redis:6379/0", "realtime needs Redis without PostgreSQL"
    refute_includes File.read("#{@root}/Dockerfile"), "libpq"
  end

  def test_mysql_app
    with_database_yml("mysql2")
    generate(%(gem "gemstack"\ngem "gemstack-db"\n))
    compose = File.read("#{@root}/compose.yaml")
    dockerfile = File.read("#{@root}/Dockerfile")

    assert_includes compose, "image: mysql:8.4"
    assert_includes compose, "DATABASE_URL: mysql2://app:${MYSQL_PASSWORD:?set MYSQL_PASSWORD}@db:3306/app"
    assert_includes dockerfile, "default-libmysqlclient-dev"
    assert_includes dockerfile, "libmariadb3"
  end

  def test_warns_about_local_gem_paths
    generate(%(path "/src/gemstack/gems" do\n  gem "gemstack"\nend\n))

    assert_includes @out.string, "bundle cache --all"
  end
end
