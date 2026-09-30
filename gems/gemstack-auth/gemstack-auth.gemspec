# frozen_string_literal: true

# All GemStack gems share one version; change it with `rake version:set[x.y.z]`.
version = "0.3.0"

Gem::Specification.new do |spec|
  spec.name = "gemstack-auth"
  spec.version = version
  spec.summary = "GemStack auth: Argon2id passwords, cookie sessions, API tokens, policies"
  spec.authors = ["Adware Technologies", "Shoaib Malik"]
  spec.email = ["gemstack26@gmail.com"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/gemstack-rb/gemstack"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["README.md", "LICENSE.txt", "CHANGELOG.md", "lib/**/*.rb"]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/gemstack-rb/gemstack/tree/main/gems/gemstack-auth"
  spec.metadata["changelog_uri"] = "https://github.com/gemstack-rb/gemstack/blob/main/gems/gemstack-auth/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/gemstack-rb/gemstack/issues"
  spec.metadata["documentation_uri"] = "https://github.com/gemstack-rb/gemstack/tree/main/docs"

  spec.add_dependency "argon2", "~> 2.3"
  spec.add_dependency "gemstack", version
  # Verifying legacy bcrypt hashes needs bcrypt in the app's Gemfile (optional).
end
