# Research assistant bundle walkthrough.
#
# Mirrors upstream `vendor/activegraph-packs/bundles/examples/research_example.py`:
#   1. build the research assistant bundle
#   2. ingest two related papers
#   3. drain behaviors (paper/author/venue, observations, idea atoms, directions)
#   4. create an experiment for the first research direction
#
# The upstream example passes `min_atoms_for_synthesis`, but the vendor's own
# `packs/research/settings.py` names that `min_ideas_for_direction`; this port
# uses the current settings name.
#
# Run from the repository root:
#
#   crystal run examples/research_assistant.cr

require "../src/chronicle-packs"
require "json"

puts "=" * 60
puts "Research Bundle - Crystal demo"
puts "=" * 60

store, graph, runtime = Chronicle::Packs::Bundles.build_research_assistant(
  research_settings: Chronicle::Packs::Research::ResearchSettings.new(
    min_coherence_for_hypothesis: 0.45,
    max_ideas_per_paper: 5,
    min_ideas_for_direction: 2,
  ),
  memory_gateway_settings: Chronicle::Packs::MemoryGateway::MemoryGatewaySettings.new(
    acceptance_threshold: 0.65,
  ),
)

puts "\nPacks loaded (#{runtime.loaded_packs.size}): #{runtime.loaded_packs.sort.join(", ")}"

puts "\n[1] Ingesting paper 1: Attention Is All You Need..."
Chronicle::Packs::Research.ingest_research_paper_fn(
  graph,
  title: "Attention Is All You Need",
  abstract_text: "We propose the Transformer, a model architecture eschewing " \
                 "recurrence and instead relying entirely on an attention mechanism " \
                 "to draw global dependencies between input and output. The Transformer " \
                 "allows for more parallelization and achieves a new state of the art " \
                 "in translation.",
  authors: "Vaswani, Shazeer, Parmar, Uszkoreit",
  venue: "NeurIPS 2017",
  year: 2017,
  keywords: ["attention", "transformer", "translation", "parallelization"],
)
runtime.run_until_idle

puts "[2] Ingesting paper 2: BERT..."
Chronicle::Packs::Research.ingest_research_paper_fn(
  graph,
  title: "BERT: Pre-training of Deep Bidirectional Transformers",
  abstract_text: "We introduce BERT, a new language representation model which " \
                 "stands for Bidirectional Encoder Representations from Transformers. " \
                 "BERT is designed to pre-train deep bidirectional representations from " \
                 "unlabeled text by jointly conditioning on both left and right context " \
                 "in all layers. Fine-tuned BERT achieves state-of-the-art results on " \
                 "NLP benchmarks.",
  authors: "Devlin, Chang, Lee, Toutanova",
  venue: "NAACL 2019",
  year: 2019,
  keywords: ["bert", "pretraining", "transformers", "language", "bidirectional"],
)
runtime.run_until_idle

counts = {
  "papers"              => "paper",
  "authors"             => "author",
  "venues"              => "venue",
  "observations"        => "observation",
  "idea_atoms"          => "idea_atom",
  "research_directions" => "research_direction",
}
puts "\nAfter two papers:"
counts.each { |label, type| puts "  #{label.ljust(20)} #{graph.objects(type: type).size}" }

puts "\nResearch directions:"
directions = graph.objects(type: "research_direction")
directions.each do |direction|
  data = JSON.parse(direction.data)
  title = data["title"]?.try(&.as_s?) || ""
  puts "  [#{direction.id.ljust(24)}] #{title[0, 60].inspect} conf=#{data["confidence"]?}"
end

if direction = directions.first?
  puts "\n[3] Creating experiment for direction #{direction.id}..."
  Chronicle::Packs::Research.create_experiment_fn(
    graph,
    title: "Evaluate transformer pretraining on low-resource NLP tasks",
    hypothesis: "BERT-style bidirectional pretraining outperforms GPT-style " \
                "autoregressive pretraining on low-resource NLP benchmarks.",
    direction_id: direction.id,
  )
  runtime.run_until_idle

  experiments = graph.objects(type: "experiment")
  puts "  experiments: #{experiments.size}"
  experiments.each do |experiment|
    data = JSON.parse(experiment.data)
    title = data["title"]?.try(&.as_s?) || ""
    puts "  [#{experiment.id.ljust(16)}] status=#{data["status"]?} #{title[0, 50].inspect}"
  end
end

events = store.iter_events
puts "\nEvent log (#{events.size} events):"
event_counts = Hash(String, Int32).new(0)
events.each { |event| event_counts[event.type] += 1 }
event_counts.to_a.sort_by { |entry| {-entry[1], entry[0]} }.each do |entry|
  puts "  #{entry[1].to_s.rjust(3)}  #{entry[0]}"
end

puts "\nDone."
