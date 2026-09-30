# frozen_string_literal: true

require "gemstack/storage"
require "tmpdir"

module GemStack
  module Storage
    # Tests store files on disk in a temporary directory, cleared after each test.
    module Testing
      def before_setup
        super
        @gemstack_storage_root = Dir.mktmpdir("gemstack-storage")
        Storage.service = Services::Disk.new(root: @gemstack_storage_root, path: Storage.config.path)
      end

      def after_teardown
        FileUtils.rm_rf(@gemstack_storage_root) if @gemstack_storage_root
        Storage.reset!
        super
      end

      # Stores a file as if the browser had uploaded it; returns its signed_id.
      def upload_fixture(content, filename: "file.png", content_type: "image/png")
        key = Storage.generate_key("uploads", filename, content_type)
        Storage.upload(key, StringIO.new(content), content_type: content_type)
        Storage.sign(key, purpose: "upload")
      end
    end
  end
end
