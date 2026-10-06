# frozen_string_literal: true

require "test_helper"
require "open3"

# The server against a real client implementation: Node.js's built-in
# WebSocket (undici, the WHATWG API browsers implement). Skipped without Node 22+.
class WebSocketInteropTest < Minitest::Test
  include RealtimeServer

  SCRIPT = <<~JS
    const ws = new WebSocket(`ws://127.0.0.1:${process.argv[1]}/api/realtime`);
    const seen = [];
    let result = null;
    const done = (value) => { result = value; ws.close(1000); };
    ws.onclose = ({ code }) => { clearTimeout(timer); console.log(JSON.stringify({ ...result, code })); };
    ws.onmessage = ({ data }) => {
      const message = JSON.parse(data);
      seen.push(message.type);
      if (message.type === "welcome") ws.send(JSON.stringify({ type: "subscribe", channel: "chat", ref: 1 }));
      if (message.type === "subscribed") ws.send(JSON.stringify({ type: "message", channel: "chat", event: "say", data: { body: "x".repeat(200000 / 2) }, ref: 2 }));
      if (message.type === "reply") ws.send(JSON.stringify({ type: "message", channel: "chat", event: "big", ref: 3 }));
      if (message.type === "event" && message.event === "big") done({ seen, size: message.data.payload.length });
    };
    ws.onerror = (e) => { console.log(JSON.stringify({ error: String(e.message || e) })); process.exit(1); };
    const timer = setTimeout(() => { console.log(JSON.stringify({ timeout: seen })); process.exit(1); }, 5000);
  JS

  def setup
    _, status = Open3.capture2e("node", "-e", "process.exit(typeof WebSocket === 'function' ? 0 : 1)")
    skip "needs Node.js 22+ (global WebSocket)" unless status.success?
  rescue Errno::ENOENT
    skip "needs Node.js"
  end

  def test_a_real_client
    GemStack::Realtime.reset!
    GemStack::Realtime.broker = GemStack::Realtime::Brokers::Memory.new
    GemStack::Realtime.channels.clear
    GemStack.config.realtime.max_message_size = 256 * 1024
    GemStack.channels do
      channel "chat"
      receive "chat" do |message|
        GemStack.broadcast("chat", "big", { payload: "y" * 200_000 }) if message.event == "big"
        { "length" => message.data.to_h["body"].to_s.length }
      end
    end
    start_server
    out, status = Open3.capture2e("node", "-e", SCRIPT, @port.to_s)
    result = JSON.parse(out.lines.last)

    assert status.success?, out
    assert_equal 200_000, result["size"], "a 200 KB event (64-bit length frame) arrives intact"
    assert_equal %w[welcome subscribed reply], result["seen"].first(3)
    assert_equal 1000, result["code"], "the close handshake completes"
  ensure
    GemStack.config.realtime.max_message_size = 64 * 1024
    stop_server
  end
end
