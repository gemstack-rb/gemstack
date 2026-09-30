# frozen_string_literal: true

# Personal API tokens: send `Authorization: Bearer <token>` instead of a cookie.
#   GET /api/auth/tokens · POST /api/auth/tokens · DELETE /api/auth/tokens/:id
class ApiTokensController < ApplicationController
  before :require_login
  before :require_session, only: %i[create destroy] # a leaked token can't mint or revoke tokens

  accepts :create do
    required :name, :string, max_length: 100
  end
  returns :index, [ApiTokenSerializer]
  returns :create, NewApiTokenSerializer

  def index = render(current_user.auth_tokens_dataset.api.order(Sequel.desc(:created_at)), serializer: ApiTokenSerializer)

  def create
    token, id = GemStack::Auth::Tokens.issue(current_user.id, purpose: "api", name: input[:name])
    render NewApiTokenSerializer::Result.new(token: token, api_token: AuthToken[id]),
           status: :created, serializer: NewApiTokenSerializer
  end

  def destroy
    revoked = GemStack::Auth::Tokens.revoke(params[:id], user_id: current_user.id)
    raise GemStack::NotFound, "API token not found" unless revoked
  end

  private

  def require_session
    return if authenticated_by == :session

    raise GemStack::Forbidden.new("Manage API tokens from the app.", code: "session_required")
  end
end
