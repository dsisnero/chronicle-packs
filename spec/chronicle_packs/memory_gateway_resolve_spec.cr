require "spec"
require "digest"
require "../spec_helper"

# Memory Gateway slice 2a: the evidence-authoritative query resolver.

module ResolveQuerySupport
  extend self

  def with_query_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ActivityNormalizer.pack).should be_true
    rt.load_pack(Chronicle::Packs::Attention.pack).should be_true
    rt.load_pack(Chronicle::Packs::EvalOutcome.pack).should be_true
    rt.load_pack(Chronicle::Packs::MemoryGateway.pack).should be_true
    yield store, graph, rt
  end

  def add_evidence(graph, rt, content : String, source_surface_id : String = "chat/sess_1", source_ref : String = "msg_1", normalized_metadata : Hash(String, JSON::Any) = {} of String => JSON::Any)
    item = graph.add_object("acquired_item", JSON.build do |json|
      json.object do
        json.field "source_surface_id", source_surface_id
        json.field "dedup_key", "dedup_#{content.hash.abs}"
        json.field "source_ref", source_ref
        json.field "source_hash", "0" * 64
        json.field "replay_mode", "reference_only"
        json.field "replay_payload_ref", ""
        json.field "replay_payload_hash", "0" * 64
        json.field "media_type", "text/plain"
        json.field "importer_id", "chatgpt_export"
        json.field "importer_version", "1.0.0"
      end
    end)
    graph.add_object("acquired_content", JSON.build do |json|
      json.object do
        json.field "acquired_item_id", item.id
        json.field "normalized_content", content
        json.field "normalized_metadata", normalized_metadata
        json.field "source_category", "communication"
        json.field "connection_path", "export"
        json.field "is_fixture", true
      end
    end)
  end
end

include ResolveQuerySupport

describe "memory_gateway resolve_memory_query" do
  it "resolves through the evidence tier when matching current evidence exists" do
    with_query_runtime do |_store, graph, rt|
      rt.run_until_idle
      add_evidence(graph, rt, "the user prefers dark mode and reads technical docs")
      rt.run_until_idle

      result = Chronicle::Packs::MemoryGateway.resolve_memory_query_fn(graph, "dark mode preference", top_k: 5, min_score: 0.2)
      result["selected_tier"].as_s.should eq("evidence")
      result["procedure_id"].as_s.should eq("memory.raw_evidence@0.1.0")
      result["evidence_ids"].as_a.size.should eq(1)
      result["authoritative_evidence"].as_bool.should be_true
      graph.objects(type: "memory_query_resolution").size.should eq(1)
    end
  end

  it "resolves to the none tier when nothing matches" do
    with_query_runtime do |_store, graph, rt|
      rt.run_until_idle
      result = Chronicle::Packs::MemoryGateway.resolve_memory_query_fn(graph, "something entirely unmatched", top_k: 5, min_score: 0.9)
      result["selected_tier"].as_s.should eq("none")
      result["procedure_id"].as_s.should eq("memory.no_match@0.1.0")
    end
  end

  it "keeps owner-profile evidence authoritative, trust-scoped, and hidden from another subject" do
    with_query_runtime do |_store, graph, rt|
      rt.run_until_idle
      add_evidence(
        graph, rt,
        "Yohei prefers small deterministic tools for ActiveGraph.",
        source_surface_id: "profile",
        source_ref: "profile:test",
        normalized_metadata: {"subject_scope" => JSON::Any.new("owner_profile")},
      )
      rt.run_until_idle

      result = Chronicle::Packs::MemoryGateway.resolve_memory_query_fn(graph, "deterministic tools", subject_ref: "owner")
      result["selected_tier"].as_s.in?({"evidence", "annotated_evidence"}).should be_true
      result["evidence_ids"].as_a.should_not be_empty
      result["context_text"].as_s.should start_with("[authoritative-evidence]")
      result["authoritative_evidence"].as_bool.should be_true

      Chronicle::Packs::EvalOutcome._emit_event(graph, "outcome.helped", {
        "artifact_id" => JSON::Any.new("answer:1"), "artifact_type" => JSON::Any.new("answer"),
        "source_context" => JSON::Any.new({
          "source_ref" => JSON::Any.new("profile"), "source_kind" => JSON::Any.new("connector_surface"),
          "domain" => JSON::Any.new("preferences"), "query_scope" => JSON::Any.new("owner_preferences"),
        }),
      }, "owner:test")
      rt.run_until_idle

      trusted = Chronicle::Packs::MemoryGateway.resolve_memory_query_fn(
        graph, "deterministic tools", subject_ref: "owner",
        source_domain: "preferences", query_scope: "owner_preferences",
      )
      trusted["context_text"].as_s.should contain("trust=supported")

      other = Chronicle::Packs::MemoryGateway.resolve_memory_query_fn(graph, "deterministic tools", subject_ref: "someone_else")
      other["evidence_ids"].as_a.should be_empty
    end
  end
end
