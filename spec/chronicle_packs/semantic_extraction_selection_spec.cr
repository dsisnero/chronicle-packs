require "spec"
require "../spec_helper"

# Semantic Extraction selection path: LLM-upgrade seeding (D025 stage two)
# and extract_selected_evidence — settle an exact-span request without
# giving the caller provider access.

module SelectionSupport
  extend self

  def with_semantic_runtime(settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if settings
      rt.load_pack(Chronicle::Packs::SemanticExtraction.pack, JSON.parse(settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::SemanticExtraction.pack).should be_true
    end
    yield store, graph, rt
  end

  def reset_provider
    Chronicle::Packs::LLMProvider.configured = nil
    Chronicle::Packs::LLMProvider.provider_instance = nil
  end

  def SelectionSupport.add_evidence(graph, text = "alice prefers dark mode", revision_id = "rev_1", evidence_id = "evidence_1")
    graph.add_object("activity_evidence", JSON.build do |json|
      json.object do
        json.field "evidence_identity", "ev_#{evidence_id}"
        json.field "evidence_id", evidence_id
        json.field "revision_id", revision_id
        json.field "revision_number", 1
        json.field "source_surface_id", "chat/sess_1"
        json.field "source_category", "communication"
        json.field "connection_path", "export"
        json.field "source_ref", "msg_1"
        json.field "importer_id", "i"
        json.field "importer_version", "1"
        json.field "status", "current"
        json.field "acquired_item_id", "acquired_item_1"
        json.field "acquired_content_id", "acquired_content_1"
        json.field "dedup_key", "d1"
        json.field "content_hash", "0" * 64
        json.field "replay_mode", "reference_only"
        json.field "replay_payload_ref", ""
        json.field "replay_payload_hash", "0" * 64
        json.field "replay_complete", false
        json.field "media_type", "text/plain"
        json.field "acquired_at_event_id", "evt_1"
        json.field "normalized_content", text
        json.field "normalized_metadata", JSON::Any.new({} of String => JSON::Any)
      end
    end)
  end

  def add_request(graph, evidence_id, revision_id, selections, facets, request_id = "req_1", selection_id = "sel_1")
    graph.add_object("selection_extraction_request", JSON.build do |json|
      json.object do
        json.field "request_identity", request_id
        json.field "evidence_id", evidence_id
        json.field "revision_id", revision_id
        json.field "selection_id", selection_id
        json.field "selections", JSON::Any.new(selections.map { |s| JSON::Any.new(s) })
        json.field "requested_facets", JSON::Any.new(facets.map { |f| JSON::Any.new(f) })
        json.field "status", "proposed"
        json.field "run_ids", JSON::Any.new([] of JSON::Any)
        json.field "annotation_ids", JSON::Any.new([] of JSON::Any)
      end
    end)
  end
end

describe "semantic extraction selection path" do
  describe "_llm_upgrade_active" do
    it "is false when the upgrade is switched off" do
      SelectionSupport.reset_provider
      settings = Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.from_json(%({"llm_upgrade_enabled":false}))
      Chronicle::Packs::SemanticExtraction._llm_upgrade_active(settings).should be_false
    end

    it "is false without a configured provider, true with one" do
      SelectionSupport.reset_provider
      settings = Chronicle::Packs::SemanticExtraction::SemanticExtractionSettings.new
      Chronicle::Packs::SemanticExtraction._llm_upgrade_active(settings).should be_false

      Chronicle::Packs::LLMProvider.configured = Chronicle::Packs::LLMProvider::ResolvedLLMProvider.new(provider: "anthropic", source: "spec", api_key_env: "ANTHROPIC_API_KEY", model: nil)
      Chronicle::Packs::SemanticExtraction._llm_upgrade_active(settings).should be_true
      SelectionSupport.reset_provider
    end
  end

  it "seeds an LLM-upgraded profile and candidate extractor state when a provider is configured" do
    SelectionSupport.reset_provider
    Chronicle::Packs::LLMProvider.configured = Chronicle::Packs::LLMProvider::ResolvedLLMProvider.new(provider: "anthropic", source: "spec", api_key_env: "ANTHROPIC_API_KEY", model: nil)
    SelectionSupport.with_semantic_runtime do |_store, graph, rt|
      rt.run_until_idle

      profile_data = JSON.parse(graph.objects(type: "extraction_profile").first.data)
      default_facets = profile_data["default_facets"].as_a.map(&.as_s)
      default_facets.should contain("event_mention")
      default_facets.should contain("relation_mention")
      extractor_by_facet = profile_data["extractor_by_facet"].as_h
      extractor_by_facet["event_mention"].as_s.should eq("semantic.llm@0.1.0")
      extractor_by_facet["relation_mention"].as_s.should eq("semantic.llm@0.1.0")

      states = graph.objects(type: "annotation_extractor_state")
      states.any? { |obj| JSON.parse(obj.data)["extractor_id"].as_s == "semantic.llm" }.should be_true
    end
    SelectionSupport.reset_provider
  end

  it "settles a selection extraction request to completed with runs and annotations" do
    SelectionSupport.reset_provider
    SelectionSupport.with_semantic_runtime do |_store, graph, rt|
      rt.run_until_idle
      text = "alice prefers dark mode"
      evidence_obj = SelectionSupport.add_evidence(graph, text)
      rt.run_until_idle

      exact_hash = Digest::SHA256.hexdigest(text)
      request = SelectionSupport.add_request(graph, evidence_obj.id, "rev_1", [{"start" => JSON::Any.new(0), "end" => JSON::Any.new(text.size), "exact_hash" => JSON::Any.new(exact_hash)}], ["assertion"])
      rt.run_until_idle

      request_data = JSON.parse(graph.get_object(request.id).not_nil!.data)
      request_data["status"].as_s.should eq("completed")
      request_data["run_ids"].as_a.should_not be_empty
      request_data["annotation_ids"].as_a.should_not be_empty
      settled = graph.events.any? { |e| e.type == "semantic.selection_extraction_settled" }
      settled.should be_true
    end
  end

  it "fails closed when the evidence does not exist" do
    SelectionSupport.reset_provider
    SelectionSupport.with_semantic_runtime do |_store, graph, rt|
      rt.run_until_idle
      request = SelectionSupport.add_request(graph, "missing_evidence", "rev_1", [] of Hash(String, JSON::Any), ["assertion"])
      rt.run_until_idle

      request_data = JSON.parse(graph.get_object(request.id).not_nil!.data)
      request_data["status"].as_s.should eq("failed")
      request_data["error"].as_s.should eq("evidence_not_found")
    end
  end

  it "fails closed on a revision mismatch" do
    SelectionSupport.reset_provider
    SelectionSupport.with_semantic_runtime do |_store, graph, rt|
      rt.run_until_idle
      evidence_obj = SelectionSupport.add_evidence(graph, "alice prefers dark mode", revision_id: "rev_1")
      rt.run_until_idle

      request = SelectionSupport.add_request(graph, evidence_obj.id, "rev_STALE", [] of Hash(String, JSON::Any), ["assertion"])
      rt.run_until_idle

      request_data = JSON.parse(graph.get_object(request.id).not_nil!.data)
      request_data["status"].as_s.should eq("failed")
      request_data["error"].as_s.should eq("revision_mismatch")
    end
  end
end
