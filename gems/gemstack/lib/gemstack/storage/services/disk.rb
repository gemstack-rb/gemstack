# frozen_string_literal: true

require "fileutils"

module GemStack
  module Storage
    module Services
      # Files on the local disk. Signed URLs point at Storage::Endpoint, so
      # the browser code is identical to S3's: PUT to upload, GET to download.
      class Disk
        attr_reader :root, :path

        def initialize(root:, path:)
          @root = File.expand_path(root)
          @path = path
        end

        def upload(key, io, content_type: nil) # rubocop:disable Lint/UnusedMethodArgument
          target = path_for(key)
          FileUtils.mkdir_p(File.dirname(target))
          File.open("#{target}.part", "wb") { |file| IO.copy_stream(io, file) }
          File.rename("#{target}.part", target)
          key
        end

        def download(key) = File.binread(path_for(key))
        def exist?(key) = File.file?(path_for(key))

        def delete(key)
          FileUtils.rm_f(path_for(key))
          true
        end

        def size(key) = File.size(path_for(key))

        def presigned_upload(key, content_type:, byte_size:, expires_in:)
          token = Storage.sign({ "k" => key, "t" => content_type, "n" => byte_size }, purpose: "disk-put",
                                                                                      expires_in: expires_in)
          { url: "#{path}/#{token}", method: "PUT", headers: { "content-type" => content_type } }
        end

        def url(key, expires_in:, disposition:, filename: nil)
          token = Storage.sign({ "k" => key, "d" => disposition, "f" => filename }, purpose: "disk-get",
                                                                                    expires_in: expires_in)
          "#{path}/#{token}"
        end

        # Keys never escape the root (no "..", no absolute paths).
        def path_for(key)
          key = key.to_s
          if key.empty? || key.start_with?("/") || key.split("/").any? { |part| part.empty? || part.start_with?(".") }
            raise ArgumentError, "invalid storage key #{key.inspect}"
          end

          File.join(root, key)
        end
      end
    end
  end
end
