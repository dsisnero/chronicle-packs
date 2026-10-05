# Email assistant bundle walkthrough.
#
# Mirrors upstream `vendor/activegraph-packs/bundles/examples/email_assistant_example.py`:
#   1. build the email assistant bundle
#   2. ingest an inbound external email
#   3. drain behaviors
#   4. inspect the source, message, thread, intent, entity, and principal objects
#
# The upstream example passes `auto_extract_entities` / `dedup_similarity_threshold`,
# but the vendor's own `packs/entity/settings.py` names those
# `extract_from_raw_sources` / `resolution_similarity_threshold`; this port uses
# the current settings names.
#
# Run from the repository root:
#
#   crystal run examples/email_assistant.cr

require "../src/chronicle-packs"
require "json"

OWNER = "alice@example.com"

puts "=" * 60
puts "Email Assistant Bundle - Crystal demo"
puts "=" * 60

store, graph, runtime = Chronicle::Packs::Bundles.build_email_assistant(
  identity_settings: Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(
    %({"owner_identifiers":["#{OWNER}"],"default_external_role":"external"}),
  ),
  email_settings: Chronicle::Packs::Email::EmailSettings.new(
    require_approval_for_external: true,
    trusted_domains: ["example.com"],
    owner_email_addresses: [OWNER],
  ),
  entity_settings: Chronicle::Packs::Entity::EntitySettings.from_json(
    %({"extract_from_raw_sources":true,"resolution_similarity_threshold":0.85}),
  ),
)

puts "\nPacks loaded (#{runtime.loaded_packs.size}): #{runtime.loaded_packs.sort.join(", ")}"

puts "\n[1] Ingesting inbound email from external founder..."
Chronicle::Packs::Email.ingest_email_fn(
  graph,
  message_id: "<msg001@startup.io>",
  from_addr: "founder@acme-startup.io",
  to_addrs: [OWNER],
  subject: "Partnership opportunity - Acme Startup",
  body_text: "Hi Alice, I'm Sarah Chen, CEO of Acme Startup. We're building " \
             "AI-powered supply chain optimization. We raised $3M seed from a16z " \
             "and would love to explore a partnership or investment discussion. " \
             "Let me know if you have 30 minutes this week.",
  received_at: "2026-06-03T10:00:00Z",
)
runtime.run_until_idle

counts = {
  "sources"       => "source",
  "comm_messages" => "comm_message",
  "email_threads" => "email_thread",
  "comm_intents"  => "comm_intent",
  "entities"      => "entity",
  "principals"    => "principal",
}
puts ""
counts.each { |label, type| puts "  #{label.ljust(15)} #{graph.objects(type: type).size}" }

puts "\nComm intents:"
graph.objects(type: "comm_intent").each do |intent|
  data = JSON.parse(intent.data)
  puts "  [#{intent.id.ljust(16)}] intent=#{data["intent"]?} conf=#{data["confidence"]?}"
end

puts "\nEntities:"
graph.objects(type: "entity").each do |entity|
  data = JSON.parse(entity.data)
  puts "  [#{entity.id.ljust(16)}] type=#{data["entity_type"]?} name=#{data["name"]?}"
end

puts "\nPrincipals:"
graph.objects(type: "principal").each do |principal|
  data = JSON.parse(principal.data)
  identifiers = data["identifiers"]?.try(&.as_h?)
  ref = identifiers.try(&.["ref"]?).try(&.as_s?)
  puts "  [#{principal.id.ljust(16)}] role=#{data["role"]?} ref=#{ref}"
end

events = store.iter_events
puts "\nEvent log (#{events.size} events):"
event_counts = Hash(String, Int32).new(0)
events.each { |event| event_counts[event.type] += 1 }
event_counts.to_a.sort_by { |entry| {-entry[1], entry[0]} }.each do |entry|
  puts "  #{entry[1].to_s.rjust(3)}  #{entry[0]}"
end

puts "\nDone."
