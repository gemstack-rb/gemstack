# frozen_string_literal: true

# All GemStack gems share one version; change it with `rake version:set[x.y.z]`.
version = "0.2.5"

Gem::Specification.new do |spec|
  spec.name = "gemstack-cli"
  spec.version = version
  spec.summary = "GemStack command-line interface and generators"
  spec.authors = ["Adware Technologies", "Shoaib Malik"]
  spec.email = ["gemstack26@gmail.com"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/gemstack-rb/gemstack"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["README.md", "LICENSE.txt", "CHANGELOG.md", "lib/**/*.rb", "templates/**/*", "templates/**/.*",
                   "exe/*"]
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["gemstack", "gs"]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/gemstack-rb/gemstack/tree/main/gems/gemstack-cli"
  spec.metadata["changelog_uri"] = "https://github.com/gemstack-rb/gemstack/blob/main/gems/gemstack-cli/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/gemstack-rb/gemstack/issues"
  spec.metadata["documentation_uri"] = "https://github.com/gemstack-rb/gemstack/tree/main/docs"

  spec.add_dependency "gemstack-core", version
  spec.add_dependency "gemstack-dev", version
  spec.add_dependency "thor", "~> 1.3"
end
