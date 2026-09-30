# frozen_string_literal: true

require "open3"
require "rbconfig"

module GemStack
  module Dev
    # The Ruby and Node.js a developer runs, and how to change them — for
    # whichever version manager installed them (rbenv, rvm, asdf, mise,
    # chruby, nvm, fnm, nodenv, Volta, Homebrew…). GemStack pins versions in
    # files every manager reads (.ruby-version, .node-version, .nvmrc,
    # .tool-versions) and never assumes one manager.
    module Toolchain
      MIN_RUBY = "3.3"
      MIN_NODE = [20, 9].freeze # Next.js 16
      LTS_NODE = "22"

      # [pattern in the executable's path, manager name]; the first match wins.
      RUBY_MANAGERS = [
        [%r{/\.rbenv/}, :rbenv], [%r{/\.rvm/|/rvm/rubies/}, :rvm], [%r{/\.asdf/|/asdf/installs/}, :asdf],
        [%r{/mise/installs/|/\.local/share/mise/}, :mise], [%r{/\.rubies/|/opt/rubies/}, :chruby],
        [%r{/(?:opt/)?homebrew/|/usr/local/Cellar/}, :homebrew]
      ].freeze
      NODE_MANAGERS = [
        [%r{/\.nvm/}, :nvm], [%r{/fnm/|/\.fnm/|fnm_multishells}, :fnm], [%r{/\.nodenv/}, :nodenv],
        [%r{/\.asdf/|/asdf/installs/}, :asdf], [%r{/mise/installs/|/\.local/share/mise/}, :mise],
        [%r{/\.volta/}, :volta], [%r{/(?:opt/)?homebrew/|/usr/local/Cellar/}, :homebrew]
      ].freeze

      module_function

      def ruby_manager(path = RbConfig.ruby) = detect(RUBY_MANAGERS, path)
      def node_manager(path) = path && detect(NODE_MANAGERS, path)

      def detect(managers, path)
        managers.find { |pattern, _| path.to_s.match?(pattern) }&.last
      end

      # How to install and select a Ruby, with the manager in use.
      def ruby_hint(version, manager = ruby_manager)
        {
          rbenv: "rbenv install #{version} && rbenv local #{version}",
          rvm: "rvm install #{version} && rvm use #{version}",
          asdf: "asdf install ruby #{version} && asdf set ruby #{version}",
          mise: "mise use ruby@#{version}",
          chruby: "ruby-install ruby #{version}, then: chruby #{version}",
          homebrew: "brew upgrade ruby (or install #{version} with rbenv, rvm, asdf or mise)"
        }.fetch(manager, "install Ruby #{version} (e.g. with rbenv, rvm, asdf or mise) and make it the active Ruby")
      end

      # How to install and select a Node.js, with the manager in use.
      def node_hint(version, manager)
        {
          nvm: "nvm install #{version} && nvm use #{version}",
          fnm: "fnm install #{version} && fnm use #{version}",
          nodenv: "nodenv install #{version} && nodenv local #{version}",
          asdf: "asdf install nodejs #{version} && asdf set nodejs #{version}",
          mise: "mise use node@#{version}",
          volta: "volta install node@#{version}",
          homebrew: "brew install node@#{version} (or use nvm, fnm, asdf or mise)"
        }.fetch(manager, "install Node.js #{version} (e.g. with nvm, fnm, asdf or mise) and make it the active node")
      end

      # { version: "22.11.0", path: "/…/bin/node" } or nil when there's no node.
      def node(run = ->(*cmd) { Open3.capture2e(*cmd) })
        out, status = run.call("node", "-p", "process.version + ' ' + process.execPath")
        return nil unless status.success?

        version, path = out.strip.split(" ", 2)
        { version: version.delete_prefix("v"), path: path }
      rescue SystemCallError
        nil
      end

      def node_ok?(version) = (version.to_s.split(".").map(&:to_i) <=> MIN_NODE) >= 0
      def ruby_ok?(version = RUBY_VERSION) = Gem::Version.new(version) >= Gem::Version.new(MIN_RUBY)

      # The Node.js version new apps pin: the one running `gemstack new` when
      # it's new enough, else the current LTS line.
      def pinned_node_version(run = ->(*cmd) { Open3.capture2e(*cmd) })
        found = node(run)
        found && node_ok?(found[:version]) ? found[:version] : LTS_NODE
      end
    end
  end
end
