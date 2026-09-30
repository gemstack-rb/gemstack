# frozen_string_literal: true

module GemStack
  module Cache
    # Caches nothing: fetch always runs its block. The default in tests, so
    # tests never depend on state cached by earlier tests.
    class NullStore < Store
      def clear = true
      def increment(_key, by = 1, **) = by

      private

      def read_entry(_key) = MISSING
      def write_entry(_key, _value, _expires_in) = true
      def delete_entry(_key) = false
    end
  end
end
