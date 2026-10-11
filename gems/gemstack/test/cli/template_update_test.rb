# frozen_string_literal: true

require "test_helper"

# `gemstack update --templates`: the app was made from "old" templates (a copy
# of today's with one file changed and one missing); the update brings it to
# today's templates without touching the app owner's edits.
class TemplateUpdateTest < Minitest::Test
  CHANGED = "frontend/next.config.ts" # differs between the old and the new templates
  ADDED = "bin/gsk"                   # only in the new templates
  STABLE = "config/puma.rb"           # identical in both

  def setup
    @tmp = Dir.mktmpdir("gemstack-template-update")
    @old = File.join(@tmp, "old-templates")
    FileUtils.cp_r(GemStack::CLI::Generator::TEMPLATES, @old)
    path = File.join(@old, "frontend/next.config.ts")
    File.write(path, File.read(path).sub(/^  output: .*\n/, ""))
    FileUtils.rm(File.join(@old, "app/bin/gsk"))
    @root = File.join(@tmp, "shop")
    GemStack::CLI::AppGenerator.new(@root, { skip_install: true, skip_git: true, templates: @old },
                                    output: StringIO.new).run
    @out = StringIO.new
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def read(path) = File.read(File.join(@root, path))
  def write(path, content) = File.write(File.join(@root, path), content)
  def exists?(path) = File.exist?(File.join(@root, path))

  def update(answers: nil, old_templates: @old, **)
    prompt = answers && ->(_question) { answers.shift }
    GemStack::CLI::TemplateUpdate.new(root: @root, from: "0.3.5", output: @out, interactive: !answers.nil?,
                                      prompt: prompt, old_templates: old_templates, **).run
  end

  def new_template(path) = File.read(File.join(GemStack::CLI::Generator::TEMPLATES, "frontend", File.basename(path)))

  def test_an_app_nobody_edited_gets_the_new_and_changed_files
    refute exists?(ADDED)
    result = update

    assert_equal [ADDED], result.created
    assert_equal [CHANGED], result.updated
    assert File.executable?(File.join(@root, ADDED)), "modes come from the template"
    assert_includes read(CHANGED), "GEMSTACK_NEXT_OUTPUT"
    assert_equal "#{GemStack::VERSION}\n", read(".gemstack/version")
    assert_includes @out.string, "1 created, 1 updated"
  end

  def test_edits_to_files_the_release_did_not_change_are_left_alone
    write(STABLE, "#{read(STABLE)}# tuned for our servers\n")
    update

    assert_includes read(STABLE), "# tuned for our servers"
  end

  def test_an_edited_changed_file_is_left_for_you_when_not_interactive
    write(CHANGED, "#{read(CHANGED)}// ours\n")
    result = update

    assert_equal [CHANGED], result.conflicts
    assert_includes read(CHANGED), "// ours"
    refute_includes read(CHANGED), "GEMSTACK_NEXT_OUTPUT"
    assert_includes @out.string, "gemstack update --templates --from 0.3.5"
    refute exists?(".gemstack/version.new")
    assert_equal "#{GemStack::VERSION}\n", read(".gemstack/version"), "written by gemstack new, unchanged"
  end

  def test_unresolved_conflicts_do_not_record_the_new_version
    write(".gemstack/version", "0.3.5\n")
    write(CHANGED, "#{read(CHANGED)}// ours\n")
    update

    assert_equal "0.3.5\n", read(".gemstack/version"), "so the next run still offers the file"
  end

  def test_interactive_answers
    write(CHANGED, "#{read(CHANGED)}// ours\n")
    result = update(answers: %w[d o])

    assert_equal [CHANGED], result.updated
    assert_includes @out.string, "+++ #{CHANGED} (new)", "d shows a diff, then asks again"
    refute_includes read(CHANGED), "// ours"
  end

  def test_saving_the_new_version_next_to_yours
    write(CHANGED, "#{read(CHANGED)}// ours\n")
    result = update(answers: %w[n])

    assert_equal [CHANGED], result.saved
    assert_includes read(CHANGED), "// ours"
    assert_includes read("#{CHANGED}.new"), "GEMSTACK_NEXT_OUTPUT"
  end

  def test_merge_keeps_your_edits_and_adds_the_release_changes
    write(CHANGED, "#{read(CHANGED)}// ours\n")
    result = update(answers: %w[m])

    assert_equal [CHANGED], result.merged
    assert_includes read(CHANGED), "// ours"
    assert_includes read(CHANGED), "GEMSTACK_NEXT_OUTPUT"
    assert_includes @out.string, "1 merged"
    assert_equal "#{GemStack::VERSION}\n", read(".gemstack/version")
  end

  def test_a_merge_where_both_changed_the_same_lines_gets_conflict_markers
    # The release adds `output:` right after this comment; so do we, differently.
    write(CHANGED, read(CHANGED).sub(%r{^  // The production image.*\n}, "\\0  reactStrictMode: true,\n"))
    result = update(answers: %w[m])

    assert_equal [CHANGED], result.marked
    content = read(CHANGED)

    assert_includes content, "<<<<<<< #{CHANGED} (yours)"
    assert_includes content, "reactStrictMode: true"
    assert_includes content, ">>>>>>> #{CHANGED} (GemStack #{GemStack::VERSION})"
    assert_includes @out.string, "1 conflict: resolve the <<<<<<< markers"
  end

  def test_merge_without_the_earlier_template_asks_again
    write(CHANGED, "#{read(CHANGED)}// ours\n")
    result = update(answers: %w[m s], old_templates: [])

    assert_equal [CHANGED], result.conflicts
    assert_includes @out.string, "Can't merge"
    assert_includes read(CHANGED), "// ours"
  end

  def test_skip_keeps_yours
    write(CHANGED, "#{read(CHANGED)}// ours\n")
    result = update(answers: %w[s])

    assert_equal [CHANGED], result.conflicts
    assert_includes read(CHANGED), "// ours"
  end

  def test_a_file_you_deleted_stays_deleted
    FileUtils.rm(File.join(@root, CHANGED))
    result = update

    assert_equal [CHANGED], result.removed
    refute exists?(CHANGED)
  end

  def test_without_the_old_templates_differences_are_offered_not_applied
    FileUtils.rm(File.join(@root, ".gemstack/version")) # like apps from before this file existed
    write(CHANGED, File.read(File.join(@old, "frontend/next.config.ts")))
    result = update(old_templates: [], from: nil) # no earlier templates available (e.g. offline)

    assert_includes result.created, ADDED, "missing files are still created"
    assert_equal [CHANGED], result.conflicts, "never updated automatically"
    assert_includes @out.string, "aren't available"
  end

  # Apps without .gemstack/version are compared with every earlier release: a
  # copy matching any of them was never edited, just left behind.
  def test_an_app_older_than_its_lockfile_is_compared_with_every_release
    FileUtils.rm(File.join(@root, ".gemstack/version"))
    result = update(from: nil, old_templates: [GemStack::CLI::Generator::TEMPLATES, @old])

    assert_equal [ADDED], result.created, "added since the app's release"
    assert_equal [CHANGED], result.updated, "matches an older release: unedited"
  end

  def test_a_file_every_release_had_and_you_deleted_stays_deleted
    FileUtils.rm(File.join(@root, ".gemstack/version"))
    FileUtils.rm(File.join(@root, STABLE))
    result = update(from: nil, old_templates: [GemStack::CLI::Generator::TEMPLATES, @old])

    refute exists?(STABLE)
    assert_empty result.created & [STABLE]
  end

  def test_dry_run_writes_nothing
    before = Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).sort
    result = update(dry_run: true)

    assert_equal [ADDED], result.created
    assert_equal before, Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).sort
    assert_includes @out.string, "dry run, nothing written"
  end

  def test_up_to_date_app
    update
    @out = StringIO.new
    result = update

    assert_empty result.created + result.updated + result.conflicts
    assert_includes @out.string, "nothing to update"
  end
end

class UpdateRunsTheTemplateStepTest < Minitest::Test
  def test_after_installing_the_gems_the_new_version_updates_templates
    Dir.mktmpdir do |root|
      File.write("#{root}/Gemfile", %(gem "gemstack", "~> 0.3.5"\n))
      lock = ->(version) { File.write("#{root}/Gemfile.lock", "GEM\n  specs:\n    gemstack (#{version})\n") }
      lock.call("0.3.5")
      calls = 0
      updater = GemStack::CLI::UpdateGenerator.new(
        root: root, output: StringIO.new, latest: -> { "0.3.6" },
        bundle: ->(_gems) { lock.call("0.3.6") },
        templates: -> { calls += 1 }
      )

      assert updater.run
      assert_equal 1, calls
    end
  end
end

# The files `gemstack generate deploy` wrote are updated like the app's
# templates; the old release is a copy of today's deploy templates with an
# older Dockerfile comment, the primary_role it used to have, and no bin/deploy.
class DeployTemplateUpdateTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("gemstack-deploy-update")
    @old = File.join(@tmp, "old-templates")
    FileUtils.cp_r(GemStack::CLI::Generator::TEMPLATES, @old)
    edit(@old, "deploy/Dockerfile.tt") { |text| text.sub("# Production image for", "# Old image for") }
    edit(@old, "deploy/config/deploy.yml.tt") { |text| text.sub("primary_role: api", "primary_role: web") }
    FileUtils.rm(File.join(@old, "deploy/bin/deploy"))
    @root = File.join(@tmp, "shop")
    GemStack::CLI::AppGenerator.new(@root, { skip_install: true, skip_git: true, templates: @old },
                                    output: StringIO.new).run
    @out = StringIO.new
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def edit(root, rel)
    path = File.join(root, rel)
    File.write(path, yield(File.read(path)))
  end

  def read(path) = File.read(File.join(@root, path))
  def manifest = JSON.parse(read(".gemstack/generators.json"))["files"]

  def generate_old_deploy
    GemStack::CLI::DeployGenerator.new(root: @root, output: StringIO.new, templates: @old).run
  end

  def update(answers: nil)
    prompt = answers && ->(_question) { answers.shift }
    GemStack::CLI::TemplateUpdate.new(root: @root, from: "0.3.5", output: @out, interactive: !answers.nil?,
                                      prompt: prompt, old_templates: @old).run
  end

  def test_unedited_deploy_files_are_updated_and_new_ones_created
    generate_old_deploy
    result = update

    assert_includes result.updated, "Dockerfile"
    assert_includes read("Dockerfile"), "# Production image for"
    assert_includes result.created, "bin/deploy"
    assert File.executable?(File.join(@root, "bin/deploy"))
    assert_equal "deploy:app", manifest.dig("bin/deploy", "owner"), "so destroy deploy removes it"
    assert_equal Digest::SHA256.hexdigest(read("Dockerfile")), manifest.dig("Dockerfile", "sha256")
  end

  def test_an_edited_deploy_file_is_merged_from_the_template_it_came_from
    generate_old_deploy
    edit(@root, "config/deploy.yml") { |text| text.gsub("192.168.0.1", "203.0.113.10") }
    result = update(answers: %w[m])

    assert_equal ["config/deploy.yml"], result.merged
    config = read("config/deploy.yml")

    assert_includes config, "primary_role: api", "the release's change"
    assert_includes config, "203.0.113.10", "your server"
    refute_includes config, "<<<<<<<"
  end

  def test_a_merged_file_is_not_offered_again
    generate_old_deploy
    edit(@root, "config/deploy.yml") { |text| text.gsub("192.168.0.1", "203.0.113.10") }
    update(answers: %w[m])
    @out = StringIO.new
    result = update(answers: [])

    assert_empty result.conflicts
    refute_includes @out.string, "config/deploy.yml"
  end

  def test_apps_without_a_deploy_setup_are_left_alone
    result = update

    refute_includes result.created, "bin/deploy"
    refute File.exist?(File.join(@root, "Dockerfile"))
  end

  def test_a_file_of_your_own_with_the_same_name_is_offered_not_merged
    generate_old_deploy
    File.write(File.join(@root, "bin/deploy"), "#!/bin/sh\nexec kamal deploy\n")
    result = update(answers: %w[m s])

    assert_includes @out.string, "Can't merge"
    assert_includes result.conflicts, "bin/deploy"
    assert_equal "#!/bin/sh\nexec kamal deploy\n", read("bin/deploy")
    refute manifest.key?("bin/deploy"), "still yours"
  end
end
