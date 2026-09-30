# frozen_string_literal: true

# All GemStack gems share one version; change it with `rake version:set[x.y.z]`.
version = "0.3.0"

# Owns the `gemstack` executable; the command's code is in the gemstack gem,
# which depends on this one (so `gem install gemstack` installs both). Kept as
# its own gem because it owned the executable before 0.3.0: RubyGems refuses
# to let another gem take an installed executable over.
Gem::Specification.new do |spec|
  spec.name = "gemstack-cli"
  spec.version = version
  spec.summary = "The gemstack command (installed with the gemstack gem)"
  spec.description = "Owns the gemstack executable. The CLI itself — generators, dev server, db and jobs " \
                     "commands — is part of the gemstack gem, which installs this one."
  spec.authors = ["Adware Technologies", "Shoaib Malik"]
  spec.email = ["gemstack26@gmail.com"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/gemstack-rb/gemstack"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["README.md", "LICENSE.txt", "CHANGELOG.md", "exe/*"]
  spec.bindir = "exe"
  spec.executables = ["gemstack", "gs"]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/gemstack-rb/gemstack/tree/main/gems/gemstack-cli"
  spec.metadata["changelog_uri"] = "https://github.com/gemstack-rb/gemstack/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/gemstack-rb/gemstack/issues"
  spec.metadata["documentation_uri"] = "https://github.com/gemstack-rb/gemstack/tree/main/docs"
end
