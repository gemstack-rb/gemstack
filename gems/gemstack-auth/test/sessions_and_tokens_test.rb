# frozen_string_literal: true

require "test_helper"

class SessionsAndTokensTest < AuthTestCase
  Sessions = GemStack::Auth::Sessions
  Tokens = GemStack::Auth::Tokens

  def test_sessions_store_only_digests
    user = create_user
    token = Sessions.create(user.id, ip: "10.0.0.1", user_agent: "Browser")
    row = Sessions.dataset.first

    refute_equal token, row[:token_digest]
    assert_equal row[:id], Sessions.find(token)[:id]
    assert_nil Sessions.find("#{token}x")
    assert_nil Sessions.find("short")
  end

  def test_expired_sessions_are_not_found
    token = Sessions.create(create_user.id)
    Sessions.dataset.update(expires_at: Time.now - 1)

    assert_nil Sessions.find(token)
  end

  def test_touch_slides_the_expiry
    token = Sessions.create(create_user.id)
    Sessions.dataset.update(last_seen_at: Time.now - 3600, expires_at: Time.now + 60)
    row = Sessions.find(token)

    assert row[:touched]
    assert_operator Sessions.dataset.first[:expires_at], :>, Time.now + (29 * 24 * 3600)
    refute Sessions.find(token)[:touched]
  end

  def test_revoke_all_except_current
    user = create_user
    keep = Sessions.create(user.id)
    Sessions.create(user.id)
    Sessions.revoke_all(user.id, except: Sessions.find(keep)[:id])

    assert_equal 1, Sessions.dataset.count
  end

  def test_single_use_tokens
    user = create_user
    token, = Tokens.issue(user.id, purpose: "password_reset")
    second, = Tokens.issue(user.id, purpose: "password_reset")

    assert_nil Tokens.consume(token, purpose: "password_reset"), "a newer reset link replaces older ones"
    assert_equal user.id, Tokens.consume(second, purpose: "password_reset")[:user_id]
    assert_nil Tokens.consume(second, purpose: "password_reset"), "used once"
    assert_nil Tokens.consume(second, purpose: "email_verification")
  end

  def test_expired_tokens
    token, = Tokens.issue(create_user.id, purpose: "password_reset", expires_in: -1)

    assert_nil Tokens.consume(token, purpose: "password_reset")
  end

  def test_api_tokens
    user = create_user
    token, id = Tokens.issue(user.id, purpose: "api", name: "CI")

    assert token.start_with?("gs_")
    assert_equal id, Tokens.find(token, purpose: "api")[:id]
    refute_nil Tokens.dataset.first[:last_used_at]
    assert_equal(["CI"], Tokens.for_user(user.id).map { |t| t[:name] })
    refute Tokens.revoke(id, user_id: user.id + 1), "only the owner can revoke"
    assert Tokens.revoke(id, user_id: user.id)
    assert_nil Tokens.find(token, purpose: "api")
    assert_raises(ArgumentError) { Tokens.find(token, purpose: "nope") }
  end

  def test_cleanup
    user = create_user
    Sessions.create(user.id)
    Tokens.issue(user.id, purpose: "api")
    Tokens.issue(user.id, purpose: "password_reset")
    Sessions.dataset.update(expires_at: Time.now - 1)
    Tokens.dataset.exclude(expires_at: nil).update(expires_at: Time.now - 1)

    assert_equal({ sessions: 1, auth_tokens: 1 }, GemStack::Auth.cleanup!)
    assert_equal 1, Tokens.dataset.count
  end
end

# GemStack::Auth.user_from: the signed-in user outside controllers (realtime's identify).
class UserFromRequestTest < AuthTestCase
  def request(headers = {}) = Rack::Request.new(Rack::MockRequest.env_for("/api/realtime", headers))

  def test_session_cookie_and_api_token
    user = create_user
    session = GemStack::Auth::Sessions.create(user.id)
    token, = GemStack::Auth::Tokens.issue(user.id, purpose: "api")
    cookie = GemStack::Auth.config.cookie_name

    assert_equal user.id, GemStack::Auth.user_from(request("HTTP_COOKIE" => "#{cookie}=#{session}")).id
    assert_equal user.id, GemStack::Auth.user_from(request("HTTP_AUTHORIZATION" => "Bearer #{token}")).id
    assert_nil GemStack::Auth.user_from(request("HTTP_COOKIE" => "#{cookie}=forged"))
    assert_nil GemStack::Auth.user_from(request("HTTP_AUTHORIZATION" => "Bearer forged"))
    assert_nil GemStack::Auth.user_from(request)
  end
end
