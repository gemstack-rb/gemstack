# frozen_string_literal: true

# Base class for policies (`gemstack generate policy Order`). Everything is
# denied unless a policy allows it; see docs/authorization.md.
class ApplicationPolicy < GemStack::Policy
end
