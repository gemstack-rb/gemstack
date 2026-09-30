# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # `gemstack add FEATURE` — opt-in modules, so apps that don't use them
    # pay nothing: realtime, auth, storage.
    class AddGenerator < Generator
      FEATURES = %w[realtime auth storage].freeze

      AUTH_ROUTES = <<~RUBY
        # Authentication (gemstack add auth) — docs/authentication.md
        post "/auth/signup", to: "registrations#create"
        post "/auth/login", to: "sessions#create"
        get "/auth/me", to: "sessions#show"
        delete "/auth/logout", to: "sessions#destroy"
        post "/auth/password/forgot", to: "password_resets#create"
        post "/auth/password/reset", to: "password_resets#update"
        post "/auth/email/resend", to: "email_verifications#create"
        post "/auth/email/verify", to: "email_verifications#update"
        get "/auth/tokens", to: "api_tokens#index"
        post "/auth/tokens", to: "api_tokens#create"
        delete "/auth/tokens/:id", to: "api_tokens#destroy"
      RUBY

      MAIL_ENV = <<~ENV

        # Email. In development messages are saved to tmp/mail instead of being sent.
        # SMTP_URL=smtp://user:password@smtp.example.com:587
        # MAIL_FROM="My App <hello@example.com>"
        # APP_URL=https://example.com   # the frontend, for links in emails (default http://localhost:3000)
      ENV

      def initialize(feature, root:, output: $stdout, install: true)
        super(output: output)
        unless FEATURES.include?(feature)
          raise Thor::Error,
                "Unknown feature #{feature.inspect}. Available: #{FEATURES.join(", ")}"
        end

        @feature = feature
        @root = root
        @install = install
      end

      def run
        public_send(:"add_#{@feature}")
        self
      end

      def add_realtime
        add_gem("gemstack-realtime")
        template_files("realtime", override_root: @root).each do |rel, source|
          next if rel.start_with?("frontend/") && !File.directory?(File.join(@root, "frontend"))

          write(File.join(@root, rel), File.read(source))
        end
        add_test_support('require "gemstack/realtime/testing"', "GemStack::Realtime::Testing")
        bundle_install
      end

      STORAGE_ENV = <<~ENV

        # File storage. Development and tests store files under storage/ (git-ignored).
        # STORAGE_SERVICE=s3            # production default
        # S3_BUCKET=my-app-uploads
        # AWS_REGION=eu-west-3
        # AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...   (or an instance role)
        # S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com   # S3-compatible services
      ENV

      def add_storage
        enable_module("storage")
        ensure_base_classes(@root, :serializer)
        copy_feature_templates("storage")
        add_routes(%(post "/uploads", to: "uploads#create" # direct uploads (gemstack add storage)\n),
                   marker: "uploads#create")
        append_env_example(STORAGE_ENV, marker: "STORAGE_SERVICE")
        append_line(".gitignore", "/storage/")
        add_test_support('require "gemstack/storage/testing"', "GemStack::Storage::Testing")
        status("note", "Gemfile", "add gem \"aws-sdk-s3\" for S3 in production (docs/storage.md)")
        bundle_install
      end

      # For templates: whether `gemstack add auth` ran.
      def auth? = Generator.uses?(@root, :auth)

      def add_auth
        require_database!("auth")
        user_model = File.join(@root, "app/models/user.rb")
        if File.file?(user_model) && !File.read(user_model).include?("GemStack::Auth::User")
          raise Thor::Error, "app/models/user.rb already exists. Add `include GemStack::Auth::User` to it and " \
                             "see docs/authentication.md (\"Existing users table\") instead."
        end

        enable_module("jobs")
        enable_module("mail")
        add_gem("gemstack-auth")
        JobGenerator.install_migration(@root, output: @output) # emails are sent from background jobs
        ensure_base_classes(@root, :model, :serializer, :mailer)
        copy_feature_templates("auth", skip_migration: "*_create_auth_tables.rb")
        include_in_application_controller("GemStack::Auth::Controller")
        add_routes(AUTH_ROUTES, marker: "/auth/login")
        append_env_example(MAIL_ENV, marker: "SMTP_URL")
        add_test_support('require "gemstack/mail/testing"', "GemStack::Mail::Testing")
        add_test_support('require "gemstack/auth/testing"', "GemStack::Auth::Testing")
        bundle_install
      end

      private

      def frontend? = File.directory?(File.join(@root, "frontend"))

      def require_database!(feature)
        return if Generator.uses?(@root, :db)

        raise Thor::Error, "#{feature} stores its data in the database, and this app was created without one: " \
                           "add `require \"gemstack/db\"` to config/app.rb, a config/database.yml and a driver gem " \
                           "first (docs/database.md)"
      end

      # Writes a feature's templates (frontend/ files only when the app has
      # one). %timestamp% in a path becomes a fresh migration version, unless a
      # migration matching skip_migration already exists.
      def copy_feature_templates(name, skip_migration: nil)
        has_migration = skip_migration && !Dir.glob(File.join(@root, "db/migrations", skip_migration)).empty?
        template_files(name, override_root: @root).sort.each do |rel, source|
          next if rel.start_with?("frontend/") && !frontend?

          if rel.include?("%timestamp%")
            next status("identical", rel, "migration already present") if has_migration

            rel = rel.sub("%timestamp%", Generator.migration_timestamp(@root))
          end
          content = File.read(source)
          content = render(content, source) if rel.end_with?(".tt")
          write(File.join(@root, rel.delete_suffix(".tt")), content)
        end
      end

      def include_in_application_controller(mixin)
        path = File.join(@root, "app/controllers/application_controller.rb")
        return status("skip", path, "not found — add `include #{mixin}` yourself") unless File.file?(path)

        content = File.read(path)
        return status("identical", path, mixin) if content.include?(mixin)

        updated = content.sub(/^class ApplicationController < .*\n/) { |line| "#{line}  include #{mixin}\n" }
        return status("skip", path, "add `include #{mixin}` yourself") if updated == content

        File.write(path, updated)
        status("update", path, mixin)
      end

      def add_routes(block, marker:)
        path = File.join(@root, "config/routes.rb")
        content = File.file?(path) ? File.read(path) : ""
        return status("identical", path, "routes") if content.include?(marker)
        return status("skip", path, "no `GemStack.routes do` block — add the routes yourself") unless
          content.match?(ControllerGenerator::ROUTES_BLOCK)

        File.write(path, content.sub(ControllerGenerator::ROUTES_BLOCK) { |open| open + block.gsub(/^/, "  ") })
        status("route", path)
      end

      def append_line(file, line)
        path = File.join(@root, file)
        return unless File.file?(path)

        content = File.read(path)
        return if content.lines.map(&:strip).include?(line)

        File.write(path, "#{content.rstrip}\n#{line}\n")
        status("update", path, line)
      end

      def append_env_example(text, marker:)
        path = File.join(@root, ".env.example")
        return unless File.file?(path)

        content = File.read(path)
        return if content.include?(marker)

        File.write(path, "#{content.rstrip}\n#{text}")
        status("update", path)
      end

      # Switches a module on in config/app.rb: uncomments its require line, or
      # adds one after `require "gemstack"`. Apps from before 0.3.0 that list
      # the module's gem in the Gemfile already have it.
      def enable_module(name)
        path = File.join(@root, "config/app.rb")
        return status("identical", path, "gemstack/#{name}") if Generator.uses?(@root, name)

        content = File.file?(path) ? File.read(path) : ""
        line = %(require "gemstack/#{name}")
        updated = content.sub(%r{^#\s*require "gemstack/#{name}".*$}, line)
        updated = content.sub(/^require "gemstack"\n/) { |gemstack| "#{gemstack}#{line}\n" } if updated == content
        return status("skip", path, "add `#{line}` to config/app.rb yourself") if updated == content

        File.write(path, updated)
        status("update", path, line)
      end

      # Adds the gem inside the GemStack `path` block (checkout apps) or as a
      # versioned dependency next to gem "gemstack".
      def add_gem(name)
        path = File.join(@root, "Gemfile")
        content = File.read(path)
        return status("identical", path, name) if content.match?(/^\s*gem "#{name}"/)

        updated = content.match?(/^path ".*" do\n/) ? add_to_path_block(content, name) : add_versioned(content, name)
        if updated == content
          raise Thor::Error,
                "couldn't find where to add #{name} in the Gemfile; add `gem \"#{name}\"` yourself"
        end

        File.write(path, updated)
        status("gemfile", path, name)
      end

      # Keeps the block's gems in alphabetical order (Bundler/OrderedGems).
      def add_to_path_block(content, name)
        content.sub(/^(path ".*" do\n)((?:  gem .*\n)*)/) do
          opening = ::Regexp.last_match(1)
          lines = ::Regexp.last_match(2) # before sort_by's regexes reset last_match
          gems = (lines.lines + ["  gem \"#{name}\"\n"]).sort_by { |line| line[/"([^"]+)"/, 1] }
          opening + gems.join
        end
      end

      def add_versioned(content, name)
        content.sub(/^gem "gemstack",.*\n/) { |line| "#{line}gem \"#{name}\", \"~> #{GemStack::VERSION}\"\n" }
      end

      def add_test_support(require_line, mixin)
        path = File.join(@root, "test/test_helper.rb")
        return unless File.file?(path)

        content = File.read(path)
        return status("identical", path) if content.include?(mixin)

        content = content.sub(%(require "gemstack/testing"\n)) { |line| "#{line}#{require_line}\n" }
        content = "#{content.rstrip}\nGemStack::TestCase.include #{mixin}\n"
        File.write(path, content)
        status("update", path, mixin)
      end

      def bundle_install
        return unless @install

        status("run", "bundle install")
        install = -> { system("bundle", "install", "--quiet", chdir: @root) }
        ok = defined?(Bundler) ? Bundler.with_unbundled_env(&install) : install.call
        status("warning", "bundle install failed — run it yourself") unless ok
      end
    end
  end
end
