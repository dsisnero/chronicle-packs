require "spec"
require "../spec_helper"

# Research Pack (packs/research): paper ingestion, claim extraction, idea
# atom distillation, and hypothesis generation. Translated from upstream
# packs/research/* (revision 6639a5385518ad49f74813373c85cf96eff9adc0). All
# v0.1 behaviors are deterministic (mock stubs, no LLM/API key).

module ResearchSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def research_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "research" / "manifest.toml"
  end

  # Mirrors upstream fixtures/run_fixtures.py settings (defaults match
  # run_paper_ingestion_pipeline: min_coherence 0.5, max_ideas 4, max_claims
  # 5, min_ideas_for_direction 1).
  def with_research_runtime(
    min_coherence_for_hypothesis : Float64 = 0.5,
    max_ideas_per_paper : Int32 = 4,
    max_claims_per_paper : Int32 = 5,
    auto_synthesize : Bool = true,
    min_ideas_for_direction : Int32 = 1,
    &
  )
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::Research::ResearchSettings.new(
      min_coherence_for_hypothesis: min_coherence_for_hypothesis,
      max_ideas_per_paper: max_ideas_per_paper,
      max_claims_per_paper: max_claims_per_paper,
      auto_synthesize_directions: auto_synthesize,
      min_ideas_for_direction: min_ideas_for_direction,
    )
    rt.load_pack(Chronicle::Packs::Research.pack, JSON.parse(settings.to_json).as_h).should be_true
    Chronicle::Packs::Research.clear_research_registry
    yield store, graph, rt
  ensure
    Chronicle::Packs::Research.clear_research_registry
  end

  def ingest_research_paper(graph, title : String, abstract_text : String, authors : String, venue : String, year : Int32? = nil, keywords : Array(String)? = nil)
    Chronicle::Packs::Research.ingest_research_paper_fn(
      graph,
      title: title,
      abstract_text: abstract_text,
      authors: authors,
      venue: venue,
      year: year,
      keywords: keywords,
    )
  end

  ATTENTION_ABSTRACT = "We propose a new simple network architecture, the Transformer, based solely on " \
                       "attention mechanisms, dispensing with recurrence and convolutions entirely. " \
                       "Experiments on machine translation tasks show these models to be superior in " \
                       "quality while being more parallelizable and requiring significantly less time to train. " \
                       "We achieve 28.4 BLEU on the WMT 2014 English-to-German translation task, improving " \
                       "over the existing best results, including ensembles, by over 2 BLEU. " \
                       "On the WMT 2014 English-to-French translation task, we establish a new single-model " \
                       "state-of-the-art BLEU score of 41.0."

  def ingest_attention(graph)
    ingest_research_paper(
      graph,
      title: "Attention Is All You Need",
      abstract_text: ATTENTION_ABSTRACT,
      authors: "Ashish Vaswani, Noam Shazeer, Niki Parmar, Jakob Uszkoreit",
      venue: "NeurIPS 2017",
      year: 2017,
      keywords: ["attention", "transformer", "translation", "parallelization"],
    )
  end
end

include ResearchSpecSupport

describe Chronicle::Packs::Research do
  describe "manifest-declared surface" do
    it "matches the upstream research manifest" do
      pack = Chronicle::Packs::Research.pack
      pack.name.should eq("research")
      pack.version.should eq("0.1.2")
      pack.object_types.map(&.name).should eq(
        ["paper", "author", "venue", "method", "benchmark", "dataset", "idea_atom", "research_direction", "experiment"]
      )
      pack.relation_types.map(&.name).should eq(
        ["cites", "authored_by", "published_in", "uses_method", "reports_benchmark", "uses_dataset", "proposes_idea", "composes_direction", "tests_direction"]
      )
      pack.behaviors.map(&.name).should eq(
        ["paper_ingester", "claim_extractor", "idea_atom_extractor", "hypothesis_generator", "research_direction_synthesizer"]
      )
      pack.tools.map(&.name).should eq(["ingest_research_paper", "create_idea_atom", "create_experiment"])
      pack.settings_schema.should eq("ResearchSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(research_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Research.pack)
    end
  end

  describe "fixture: paper_ingestion_pipeline" do
    it "turns a research_paper source into Paper + Authors + Venue + claims + IdeaAtoms + Direction" do
      with_research_runtime do |_store, graph, rt|
        ingest_attention(graph)
        rt.run_until_idle

        papers = graph.objects(type: "paper")
        papers.size.should eq(1)
        paper_data = JSON.parse(papers.first.data)
        paper_data["title"].as_s.should eq("Attention Is All You Need")
        paper_data["year"].as_i.should eq(2017)
        paper_data["source_id"].as_s.should eq(graph.objects(type: "source").first.id)

        authors = graph.objects(type: "author")
        authors.size.should eq(4)
        author_names = authors.map { |a| JSON.parse(a.data)["name"].as_s }
        author_names.should contain("Ashish Vaswani")
        author_names.should contain("Jakob Uszkoreit")

        venues = graph.objects(type: "venue")
        venues.size.should eq(1)
        JSON.parse(venues.first.data)["name"].as_s.should eq("NeurIPS 2017")

        # Core's observation_extractor also fires on source.created (it loads
        # alongside research, matching upstream). Isolate the claim_extractor
        # observations by their extracted_by marker.
        observations = graph.objects(type: "observation").select do |o|
          meta = JSON.parse(o.data)["metadata"]?.try(&.as_h)
          extracted = meta.try { |m| m["extracted_by"]? }
          extracted.try(&.as_s?) == "claim_extractor"
        end
        observations.size.should eq(4)
        obs_data = JSON.parse(observations.first.data)
        obs_data["confidence"].as_f.should eq(0.75)
        obs_data["category"].as_s.should eq("fact")
        obs_data["metadata"]["extracted_by"].as_s.should eq("claim_extractor")

        idea_atoms = graph.objects(type: "idea_atom")
        idea_atoms.size.should eq(4)
        atom_data = JSON.parse(idea_atoms.first.data)
        atom_data["text"].as_s.should eq("Combining attention and transformer may yield improvements in translation.")
        atom_data["coherence_score"].as_f.should eq(0.5)
        atom_data["novelty_score"].as_f.should eq(0.4)

        directions = graph.objects(type: "research_direction")
        directions.size.should eq(2)
        titles = directions.map { |d| JSON.parse(d.data)["title"].as_s }
        titles.should contain("Research Direction: attention, transformer")
        titles.should contain("Synthesized Direction: Attention Research")

        rel_types = graph.relations.map(&.type).to_set
        rel_types.should contain("authored_by")
        rel_types.should contain("published_in")
        rel_types.should contain("proposes_idea")
        rel_types.should contain("derived_from_source")
        rel_types.should contain("grounds")
      end
    end

    it "dedups paper ingestion by source id" do
      with_research_runtime do |_store, graph, rt|
        # Same source.created event re-fired must not create a second paper.
        payload = JSON.build do |json|
          json.object do
            json.field "id", "src_dedup"
            json.field "type", "source"
            json.field "data" do
              json.object do
                json.field "kind", "research_paper"
                json.field "content", ""
                json.field "channel", "research"
                json.field "metadata" do
                  json.object do
                    json.field "title", "Attention Is All You Need"
                    json.field "abstract", ATTENTION_ABSTRACT
                    json.field "authors", "Ashish Vaswani, Noam Shazeer, Niki Parmar, Jakob Uszkoreit"
                    json.field "venue", "NeurIPS 2017"
                    json.field "year", 2017
                    json.field "keywords", JSON::Any.new(["attention", "transformer", "translation", "parallelization"].map { |k| JSON::Any.new(k) })
                  end
                end
              end
            end
          end
        end
        event = Chronicle::Event.new(
          schema_version: 1, sequence: 1, id: "evt_dedup",
          type: "object.created", actor: "research", caused_by: nil, payload: payload
        )
        ctx = Chronicle::Packs::BehaviorContext.new(
          "research",
          JSON.parse(Chronicle::Packs::Research::ResearchSettings.new.to_json).as_h,
          ->(pack_name : String) { nil.as(Hash(String, JSON::Any)?) }
        )
        settings = Chronicle::Packs::Research::ResearchSettings.new
        Chronicle::Packs::Research.paper_ingester(event, graph, ctx, settings)
        Chronicle::Packs::Research.paper_ingester(event, graph, ctx, settings)
        rt.run_until_idle

        graph.objects(type: "paper").size.should eq(1)
        graph.objects(type: "author").size.should eq(4)
      end
    end
  end

  describe "fixture: direction_synthesis" do
    it "synthesizes a direction when idea atoms converge and links an experiment to it" do
      with_research_runtime(
        min_coherence_for_hypothesis: 0.45,
        max_ideas_per_paper: 3,
        min_ideas_for_direction: 2,
      ) do |_store, graph, rt|
        ingest_research_paper(
          graph,
          title: "BERT: Pre-training of Deep Bidirectional Transformers",
          abstract_text: "We introduce BERT, which stands for Bidirectional Encoder Representations from Transformers. " \
                         "BERT is designed to pre-train deep bidirectional representations from unlabeled text " \
                         "by jointly conditioning on both left and right context in all layers. " \
                         "The pre-trained BERT model can be fine-tuned with just one additional output layer " \
                         "to create state-of-the-art models for a wide range of tasks.",
          authors: "Jacob Devlin, Ming-Wei Chang, Kenton Lee, Kristina Toutanova",
          venue: "NAACL 2019",
          year: 2019,
          keywords: ["bert", "pretraining", "transformers", "bidirectional", "representations"],
        )
        rt.run_until_idle

        ingest_research_paper(
          graph,
          title: "Language Models are Unsupervised Multitask Learners",
          abstract_text: "Natural language processing tasks, such as question answering, machine translation, " \
                         "reading comprehension, and summarization, are typically approached with supervised learning. " \
                         "We demonstrate that language models begin to learn these tasks without any explicit supervision " \
                         "when trained on a new dataset of millions of webpages called WebText. " \
                         "The capacity of the language model is essential to the success of zero-shot task transfer.",
          authors: "Alec Radford, Jeffrey Wu, Rewon Child, David Luan",
          venue: "OpenAI Blog",
          year: 2019,
          keywords: ["language", "transformers", "pretraining", "zero-shot", "multitask"],
        )
        rt.run_until_idle

        papers = graph.objects(type: "paper")
        papers.size.should eq(2)
        graph.objects(type: "idea_atom").size.should eq(6)

        directions = graph.objects(type: "research_direction")
        directions.size.should eq(4)
        graph.relations.select { |r| r.type == "composes_direction" }.size.should be >= 4

        first_direction = directions.first
        exp = Chronicle::Packs::Research.create_experiment_fn(
          graph,
          title: "Comparing BERT vs GPT pretraining on low-resource tasks",
          hypothesis: "Bidirectional context (BERT) outperforms unidirectional (GPT) on NLU benchmarks",
          direction_id: first_direction.id,
        )
        rt.run_until_idle

        experiments = graph.objects(type: "experiment")
        experiments.size.should eq(1)
        JSON.parse(experiments.first.data)["status"].as_s.should eq("proposed")
        graph.relations.select { |r| r.type == "tests_direction" }.size.should eq(1)
      end
    end
  end

  describe "hypothesis_generator gating" do
    it "skips directions when auto_synthesize_directions is false" do
      with_research_runtime(auto_synthesize: false) do |_store, graph, rt|
        ingest_attention(graph)
        rt.run_until_idle

        graph.objects(type: "research_direction").size.should eq(0)
        graph.objects(type: "idea_atom").size.should eq(4)
      end
    end

    it "skips a low-coherence atom in hypothesis_generator" do
      with_research_runtime do |_store, graph, rt|
        Chronicle::Packs::Research.create_idea_atom_fn(
          graph,
          text: "A marginal thought.",
          tags: ["obscure"],
          novelty_score: 0.6,
          coherence_score: 0.1,
        )
        rt.run_until_idle

        graph.objects(type: "research_direction").size.should eq(0)
      end
    end

    it "merges a same-tag atom into an existing direction" do
      with_research_runtime do |_store, graph, rt|
        atom1 = Chronicle::Packs::Research.create_idea_atom_fn(
          graph, text: "First thought.", tags: ["retrieval"], novelty_score: 0.6, coherence_score: 0.8
        )
        rt.run_until_idle
        Chronicle::Packs::Research.create_idea_atom_fn(
          graph, text: "Second thought.", tags: ["retrieval"], novelty_score: 0.6, coherence_score: 0.8
        )
        rt.run_until_idle

        directions = graph.objects(type: "research_direction")
        directions.size.should eq(1)
        JSON.parse(directions.first.data)["idea_atom_ids"].as_a.size.should eq(2)
        graph.relations.select { |r| r.type == "composes_direction" }.size.should eq(2)
      end
    end
  end
end
