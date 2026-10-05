# frozen_string_literal: true

require "test_helper"

# `gemstack generate …` through the command line, as users run it — the
# generator classes are tested directly elsewhere; this checks the wiring.
class GenerateCommandTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("gemstack-generate")
    FileUtils.mkdir_p(%W[#{@root}/config #{@root}/app/models #{@root}/app/jobs #{@root}/db/migrations])
    File.write("#{@root}/config/app.rb", %(require "gemstack"\nrequire "gemstack/db"\nrequire "gemstack/jobs"\n))
    File.write("#{@root}/config/routes.rb", "GemStack.routes do\nend\n")
    File.write("#{@root}/Gemfile", %(gem "gemstack"\n))
  end

  def teardown = FileUtils.rm_rf(@root)

  def gemstack(*args)
    out = StringIO.new
    $stdout = out
    Dir.chdir(@root) { GemStack::CLI.start(args) }
    out.string
  ensure
    $stdout = STDOUT
  end

  def test_generate_model
    output = gemstack("generate", "model", "Widget", "name:string")

    assert File.file?("#{@root}/app/models/widget.rb"), output
    assert_includes output, "gemstack db:migrate"
  end

  def test_generate_resource_api_only
    gemstack("g", "resource", "Gadget", "name:string", "--api-only", "--skip-contract")

    assert File.file?("#{@root}/app/controllers/gadgets_controller.rb")
    assert_includes File.read("#{@root}/config/routes.rb"), "resources :gadgets"
  end

  def test_generate_job
    output = gemstack("generate", "job", "SendDigest")

    assert File.file?("#{@root}/app/jobs/send_digest.rb"), output
  end
end
