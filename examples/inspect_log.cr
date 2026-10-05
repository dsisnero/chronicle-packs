# Inspecting the event log.
#
# The append-only log is the source of truth: every object/relation write and
# every behavior, LLM, and tool step is a durable, causally-linked event. This
# program reads it three ways:
#
#   1. human-readable CONTRACT trace      `runtime.trace.lines`
#   2. the raw event stream               `store.iter_events`
#   3. the causal chain for one object    `Chronicle::Trace.causal_chain`
#
# For durable storage, back the runtime with a `Chronicle::SQLiteEventStore`
# (see docs/bundles.md and docs/demo-server.md), or use the `chronicle-cli`
# `log` / `trace` / `replay` / `fork` / `diff` commands.
#
# Run from the repository root:
#
#   crystal run examples/inspect_log.cr

require "../src/chronicle-packs"

OWNER = "alice@example.com"

store, graph, runtime = Chronicle::Packs::Bundles.build_assistant(
  identity_settings: Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(
    %({"owner_identifiers":["#{OWNER}"]}),
  ),
)

Chronicle::Packs::Chat.submit_chat_input_fn(
  graph,
  user_ref: OWNER,
  content: "Can you help me research the new transformer paper?",
  session_id: "log-demo",
)
runtime.run_until_idle

trace_lines = runtime.trace.lines
puts "=" * 70
puts "Trace - human-readable event log (#{trace_lines.size} lines)"
puts "=" * 70
trace_lines.each { |line| puts line }

puts
puts "=" * 70
puts "Raw events (sequence | type | actor | caused_by | id)"
puts "=" * 70
store.iter_events.each do |event|
  puts "#{event.sequence.to_s.rjust(4)} | #{event.type.ljust(22)} | " \
       "#{event.actor.ljust(28)} | #{(event.caused_by || "-").ljust(10)} | #{event.id}"
end

puts
puts "=" * 70
puts "Causal chains"
puts "=" * 70
[{"chat_turn", "turn"}, {"comm_response_candidate", "response"}].each do |(type, label)|
  next unless object = graph.objects(type: type).first?
  puts "\n#{label}: #{object.id}"
  puts Chronicle::Trace.causal_chain(store.iter_events, graph, object.id)
end

puts "\nTotal events: #{store.iter_events.size}"

# The event store is the sequencing authority: `MemoryEventStore` and
# `SQLiteEventStore` both stamp each stored event with a strictly-increasing
# position, so the stream is directly encodable as a `chronicle.event-log`.
log_path = File.tempname("chronicle-assistant", ".jsonl")
events = store.iter_events
File.write(log_path, Chronicle::EventLogCodec.encode(Chronicle::EventLog.from_events(events)))

object_id = graph.objects(type: "comm_response_candidate").first?.try(&.id) || "comm_response_candidate#1"
puts "\nWrote the log to #{log_path}"
puts "Inspect it with the CLI:"
puts "  chronicle-cli log inspect --file #{log_path}"
puts "  chronicle-cli trace --file #{log_path} --object #{object_id}"
