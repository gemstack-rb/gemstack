# frozen_string_literal: true

require "test_helper"

# script/changes decides which suites `rake test:changed` runs and whether a
# pull request changed code without tests.
class ChangesTest < Minitest::Test
  load File.expand_path("../../../../script/changes", __dir__) unless defined?(GemStackChanges)
  Changes = GemStackChanges

  def test_files_map_to_their_module
    {
      "gems/gemstack/lib/gemstack/http/router.rb" => [:code, "http"],
      "gems/gemstack/lib/gemstack/http.rb" => [:code, "http"],
      "gems/gemstack/lib/gemstack/inflector.rb" => [:code, "core"],
      "gems/gemstack/lib/gemstack/serializer.rb" => [:code, "schema"],
      "gems/gemstack/lib/gemstack/job.rb" => [:code, "jobs"],
      "gems/gemstack/lib/gemstack/application.rb" => [:code, "app"],
      "gems/gemstack/lib/gemstack.rb" => [:code, "app"],
      "gems/gemstack/templates/app/Gemfile.tt" => [:code, "cli"],
      "gems/gemstack-cli/exe/gemstack" => [:code, "cli"],
      "gems/gemstack-auth/lib/gemstack/policy.rb" => [:code, "auth"],
      "gems/gemstack-realtime/lib/gemstack/realtime/server.rb" => [:code, "realtime"],
      "gems/gemstack/test/http/router_test.rb" => [:test, "http"],
      "gems/gemstack-auth/test/user_test.rb" => [:test, "auth"],
      "docs/routing.md" => nil,
      "README.md" => nil
    }.each { |file, expected| assert_equal expected, Changes.classify(file), file }
  end

  def test_suites_for_changed_files
    assert_equal %w[db http], Changes.suites(%w[gems/gemstack/lib/gemstack/http/router.rb
                                                gems/gemstack/test/db/model_test.rb docs/models.md])
    assert_empty Changes.suites(%w[docs/routing.md CHANGELOG.md])
    assert_equal :all, Changes.suites(%w[Gemfile.lock])
    assert_equal :all, Changes.suites(%w[gems/gemstack/gemstack.gemspec])
  end

  def test_code_changes_need_test_changes_in_the_same_module
    assert_equal %w[db], Changes.untested(%w[gems/gemstack/lib/gemstack/http/router.rb
                                             gems/gemstack/test/http/router_test.rb
                                             gems/gemstack/lib/gemstack/db/model.rb])
    assert_empty Changes.untested(%w[docs/routing.md README.md])
    assert_equal %w[cli], Changes.untested(%w[gems/gemstack/templates/app/Gemfile.tt])
  end

  def test_every_suite_the_script_names_exists
    subdirs = ->(path) { Dir[File.join(File.expand_path(path, __dir__), "*/")].map { |dir| File.basename(dir) } }
    suites = subdirs["../"] + %w[auth realtime]
    names = Changes::LOOSE.keys + subdirs["../../lib/gemstack"]

    assert_empty names.uniq - suites, "every module has a test suite"
  end
end
