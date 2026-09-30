# frozen_string_literal: true

# The response to creating an API token: the only time the token itself is shown.
class NewApiTokenSerializer < ApplicationSerializer
  Result = Data.define(:token, :api_token)

  attribute :token, :string
  attribute :api_token, ApiTokenSerializer
end
