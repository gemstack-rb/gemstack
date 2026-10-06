# frozen_string_literal: true

# What browsers may do over realtime connections (docs/realtime.md).
# Anything not listed here is refused. `*` matches one segment and is passed
# to the block, together with the connection's request (cookies, headers).
#
#   GemStack.broadcast("orders:#{order.id}", "order.updated", order)   # server → browsers
#
GemStack.channels do
  # Who is connecting, once per connection (nil: anonymous). A Hash with an
  # :id is also the presence metadata others see. With `gemstack add auth`:
  #   identify { |request| GemStack::Auth.user_from(request)&.then { |u| { id: u.id, name: u.name } } }

  # channel "announcements"                        # public
  # channel "orders:*" do |order_id, request|      # private
  #   Order.find_by(id: order_id)&.user_id == identity(request)&.fetch(:id)
  # end
  # channel "rooms:*", presence: true do |room_id, request|   # + who's here (usePresence)
  #   !identity(request).nil?
  # end

  # Messages browsers send with realtime.send(channel, event, data) — only to
  # channels they're subscribed to. The return value is the reply.
  # receive "rooms:*" do |message|
  #   post = Post.create!(room_id: message.params.first, body: message.data["body"], user_id: message.identity[:id])
  #   GemStack.broadcast(message.channel, "post.created", post)
  #   { id: post.id }
  # end
end
