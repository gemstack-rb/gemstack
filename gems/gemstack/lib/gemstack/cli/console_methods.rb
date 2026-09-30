# frozen_string_literal: true

module GemStack
  class CLI < Thor
    # Helpers available at the `gemstack console` prompt.
    module ConsoleMethods
      def reload!
        GemStack.application.reload!
      end
    end
  end
end
