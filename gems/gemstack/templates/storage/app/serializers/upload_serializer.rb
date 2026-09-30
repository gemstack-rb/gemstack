# frozen_string_literal: true

# Where and how the browser sends the file (see UploadsController).
class UploadSerializer < ApplicationSerializer
  Result = Data.define(:signed_id, :url, :http_method, :headers)

  attribute :signed_id, :string
  attribute :url, :string
  attribute(:method, :string) { |upload| upload.http_method }
  attribute :headers, :json
end
