# frozen_string_literal: true

# All GemStack gems share one version; change it with `rake version:set[x.y.z]`.
version = "0.4.1"

Gem::Specification.new do |spec|
  spec.name = "gemstack"
  spec.version = version
  spec.summary = "GemStack: a fast, modular Ruby web application framework with a Next.js frontend"
  spec.description = "Ruby API + Next.js with one origin: routing, controllers, models (SQLite, PostgreSQL, " \
                     "MySQL), background jobs, mail, file storage, a TypeScript contract, generators and a " \
                     "development server. Authentication and realtime are the gemstack-auth and " \
                     "gemstack-realtime gems."
  spec.authors = ["Adware Technologies", "Shoaib Malik"]
  spec.email = ["gemstack26@gmail.com"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/gemstack-rb/gemstack"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["README.md", "LICENSE.txt", "CHANGELOG.md", "lib/**/*.{rb,html}", "templates/**/*",
                   "templates/**/.*"]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/gemstack-rb/gemstack/tree/main/gems/gemstack"
  spec.metadata["changelog_uri"] = "https://github.com/gemstack-rb/gemstack/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/gemstack-rb/gemstack/issues"
  spec.metadata["documentation_uri"] = "https://github.com/gemstack-rb/gemstack/tree/main/docs"

  spec.add_dependency "bigdecimal", ">= 3.1" # schema: decimals
  spec.add_dependency "erubi", "~> 1.13"     # mail templates
  spec.add_dependency "gemstack-cli", version # the `gemstack` executable (its code is lib/gemstack/cli)
  spec.add_dependency "json", ">= 2.10"      # JSON::Coder
  spec.add_dependency "mail", "~> 2.9"
  spec.add_dependency "puma", ">= 6.4"
  spec.add_dependency "rack", "~> 3.1"
  spec.add_dependency "sequel", "~> 5.80"    # db; the driver gem (pg, mysql2, trilogy, sqlite3) is the app's
  spec.add_dependency "thor", "~> 1.3"       # the gemstack command
  spec.add_dependency "zeitwerk", "~> 2.6"
end
