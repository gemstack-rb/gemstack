# frozen_string_literal: true

require "test_helper"

# script/check-secret-files — what CI, script/release and the release workflow
# refuse to publish.
class SecretFilesTest < Minitest::Test
  load File.expand_path("../../../../script/check-secret-files", __dir__) unless defined?(GemStackSecretFiles)
  Check = GemStackSecretFiles
  TEMPLATE = "gems/gemstack/templates/deploy/dot_kamal/secrets.tt"

  def problems(files, content = {}) = Check.problems(files, read: ->(path) { content.fetch(path) })

  def test_the_repository_has_no_secret_files
    assert_empty Check.problems(Check.tracked)
  end

  def test_secret_and_data_files_are_refused
    files = %w[.env .env.production config/master.key certs/server.pem config/credentials.yml.enc
               config/secrets.yml db/dump.sql exports/leads.csv log/production.log tmp/token_secret]

    assert_equal files.sort, problems(files).map(&:first).sort
    assert_empty problems(%w[.env.example README.md config/deploy.yml lib/secret_box.rb])
  end

  def test_the_kamal_secrets_template_may_only_hold_references
    references = "KEY=$KEY\nURL=postgres://app:$PASSWORD@db/app\nCMD=$(kamal secrets fetch X)\n<% if x -%>\n# note\n"

    assert_empty problems([TEMPLATE], TEMPLATE => references)
    assert_equal [[TEMPLATE, "contains values instead of references: SECRET_KEY_BASE"]],
                 problems([TEMPLATE], TEMPLATE => "#{references}SECRET_KEY_BASE=3f9a1c\n")
  end
end
