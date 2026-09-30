# frozen_string_literal: true

# Tables used by GemStack::Auth (docs/authentication.md).
Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id, type: :Bignum
      String :email, null: false, unique: true # stored lowercased
      String :password_digest, null: false     # Argon2id
      column :email_verified_at, :timestamptz
      column :created_at, :timestamptz, null: false
      column :updated_at, :timestamptz, null: false
    end

    # One row per signed-in browser; the cookie holds a random token, the
    # table only its SHA-256 digest.
    create_table(:sessions) do
      primary_key :id, type: :Bignum
      foreign_key :user_id, :users, type: :Bignum, null: false, on_delete: :cascade, index: true
      String :token_digest, size: 64, null: false, unique: true
      column :ip, :inet
      String :user_agent
      column :created_at, :timestamptz, null: false
      column :last_seen_at, :timestamptz, null: false
      column :expires_at, :timestamptz, null: false, index: true
    end

    # API tokens, password reset and email verification tokens (digests only).
    create_table(:auth_tokens) do
      primary_key :id, type: :Bignum
      foreign_key :user_id, :users, type: :Bignum, null: false, on_delete: :cascade, index: true
      String :purpose, size: 30, null: false
      String :token_digest, size: 64, null: false, unique: true
      String :name
      String :email
      column :created_at, :timestamptz, null: false
      column :last_used_at, :timestamptz
      column :expires_at, :timestamptz
    end
  end
end
