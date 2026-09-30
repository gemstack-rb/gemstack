# frozen_string_literal: true

# Realtime channels browsers may subscribe to (docs/realtime.md). Anything not
# listed here is refused. `*` matches one segment and is passed to the block,
# together with the request (cookies, headers) for authorization.
#
#   GemStack.broadcast("orders:#{order.id}", "order.updated", order)
#
GemStack.channels do
  # channel "announcements"                        # public
  # channel "orders:*" do |order_id, request|      # private
  #   Order.find_by(id: order_id)&.user_id == current_user_id(request)
  # end
end
