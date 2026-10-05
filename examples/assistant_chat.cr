# Assistant bundle walkthrough.
#
# Mirrors upstream `vendor/activegraph-packs/bundles/examples/assistant_example.py`:
#   1. build the assistant bundle — no API key is needed, the runtime uses a
#      deterministic mock completion model
#   2. submit a chat message from the owner
#   3. drain the reactive behaviors with `run_until_idle`
#   4. inspect the durable graph objects and the event log they produced
#
# Run from the repository root:
#
#   crystal run examples/assistant_chat.cr

require "../src/chronicle-packs"
require "json"

OWNER = "alice@example.com"

puts "=" * 60
puts "Assistant Bundle - Crystal demo"
puts "=" * 60

store, graph, runtime = Chronicle::Packs::Bundles.build_assistant(
  identity_settings: Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(
    %({"owner_identifiers":["#{OWNER}"],"default_external_role":"external"}),
  ),
)

puts "\nPacks loaded: #{runtime.loaded_packs.sort.join(", ")}"

Chronicle::Packs::Chat.submit_chat_input_fn(
  graph,
  user_ref: OWNER,
  content: "I'd like to explore the new transformer paper. Can you help me research it?",
  session_id: "session-demo-1",
)

runtime.run_until_idle

puts "\nAfter submitting a chat message and draining behaviors:"
%w[chat_input comm_message comm_response_candidate chat_session chat_turn principal].each do |type|
  puts "  #{type.ljust(24)} #{graph.objects(type: type).size}"
end

puts "\nPrincipals:"
graph.objects(type: "principal").each do |principal|
  data = JSON.parse(principal.data)
  identifiers = data["identifiers"]?.try(&.as_h?)
  ref = identifiers.try(&.["ref"]?).try(&.as_s?)
  puts "  [#{principal.id.ljust(12)}] role=#{data["role"]?} ref=#{ref}"
end

puts "\nChat turns:"
graph.objects(type: "chat_turn").each do |turn|
  data = JSON.parse(turn.data)
  user = data["user_message"]?.try(&.as_s?) || "(none)"
  assistant = data["assistant_message"]?.try(&.as_s?) || "(pending)"
  puts "  [#{turn.id.ljust(12)}] turn #{data["turn_number"]?}"
  puts "      user:      #{user}"
  puts "      assistant: #{assistant}"
end

events = store.iter_events
puts "\nEvent log (#{events.size} events):"
counts = Hash(String, Int32).new(0)
events.each { |event| counts[event.type] += 1 }
counts.to_a.sort_by { |entry| {-entry[1], entry[0]} }.each do |entry|
  puts "  #{entry[1].to_s.rjust(3)}  #{entry[0]}"
end

puts "\nDone."
