require "spec"
require "../spec_helper"

# ADR 0028 v1: learned importance and trust remain distinct and explainable
# (upstream tests/test_attention_vectors.py). The vector projectors keep
# importance context-scoped and trust domain-scoped, never LLM-asserted,
# and explicit signals require an explicit owner act.

module AttentionVectorsSpecSupport
  extend self

  def with_attention_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Attention.pack).should be_true
    rt.run_until_idle
    yield store, graph, rt
  end

  def observe(graph, rt, observation_id : String, subject_ref : String, signal : String, *, context_key : String = "global", strength_milli : Int32 = 1_000, explicit : Bool = false)
    Chronicle::Packs::Attention.record_attention_observation_fn(
      graph,
      observation_id: observation_id,
      subject_ref: subject_ref,
      signal_type: signal,
      context_key: context_key,
      strength_milli: strength_milli,
      explicit: explicit,
    )
    rt.run_until_idle
  end

  def emit_outcome(graph, rt, event_type : String, artifact_id : String, source_ref : String, domain : String, query_scope : String)
    Chronicle::Packs::EvalOutcome._emit_event(graph, event_type, {
      "artifact_id"    => JSON::Any.new(artifact_id),
      "artifact_type"  => JSON::Any.new("memory_claim"),
      "source_context" => JSON::Any.new({
        "trust_sources" => JSON::Any.new([
          JSON::Any.new({
            "source_ref"  => JSON::Any.new(source_ref),
            "source_kind" => JSON::Any.new("connector_surface"),
            "domain"      => JSON::Any.new(domain),
            "query_scope" => JSON::Any.new(query_scope),
          }),
        ]),
      }),
    }, "owner:test")
    rt.run_until_idle
  end
end

include AttentionVectorsSpecSupport

describe "attention vectors (ADR 0028 v1)" do
  it "keeps importance context-scoped, explainable, and not LLM-asserted" do
    with_attention_runtime do |_store, graph, rt|
      observe(graph, rt, "o1", "message:1", "opened", context_key: "inbox")
      observe(graph, rt, "o2", "message:1", "active_dwell", context_key: "inbox", strength_milli: 500)

      inbox = Chronicle::Packs::Attention.get_importance_fn(graph, "message:1", context_key: "inbox")
      inbox["score_milli"].as_i.should be > 500
      inbox["features"].as_h.has_key?("engagement").should be_true
      inbox["evidence_refs"].as_a.map(&.as_s).should contain("o1")
      inbox["evidence_refs"].as_a.map(&.as_s).should contain("o2")
      Chronicle::Packs::Attention.get_importance_fn(graph, "message:1", context_key: "project:x")["priority_band"].as_s.should eq("unranked")

      observe(graph, rt, "o3", "message:1", "llm_judgment", context_key: "inbox")
      after_model = Chronicle::Packs::Attention.get_importance_fn(graph, "message:1", context_key: "inbox")
      after_model["score_milli"].as_i.should eq(inbox["score_milli"].as_i)
      metadata = after_model["metadata"]?.try(&.as_h)
      metadata.try(&.["llm_direct_weight"]?).try(&.as_i).should eq(0)
    end
  end

  it "requires an explicit owner act for explicit signals and an opportunity for absence" do
    with_attention_runtime do |_store, graph, rt|
      observe(graph, rt, "named-only", "task:1", "explicit_important")
      Chronicle::Packs::Attention.get_importance_fn(graph, "task:1")["priority_band"].as_s.should eq("unranked")

      observe(graph, rt, "owner-mark", "task:1", "explicit_important", explicit: true)
      marked = Chronicle::Packs::Attention.get_importance_fn(graph, "task:1")
      marked["priority_band"].as_s.should eq("high")

      expect_raises(Chronicle::Packs::PackError, /opportunity_id/) do
        Chronicle::Packs::Attention.record_attention_observation_fn(
          graph, observation_id: "bad-absence", subject_ref: "task:1", signal_type: "nonresponse_window")
      end
    end
  end

  it "reserves deterministic exploration and exposes the selection reason" do
    with_attention_runtime do |_store, graph, rt|
      observe(graph, rt, "important", "task:important", "completed")
      decision = Chronicle::Packs::Attention.rank_importance_fn(
        graph, ["task:unknown-b", "task:important", "task:unknown-a"],
        limit: 2, exploration_slots: 1,
      )
      reasons = decision["items"].as_a.map { |row| row["selection_reason"].as_s }
      reasons.should eq(["importance", "exploration"])
      decision["items"].as_a.first["subject_ref"].as_s.should eq("task:important")
      decision.should eq(Chronicle::Packs::Attention.rank_importance_fn(
        graph, ["task:unknown-b", "task:important", "task:unknown-a"],
        limit: 2, exploration_slots: 1,
      ))
    end
  end

  it "keeps source trust domain-scoped and counts only canonical outcomes" do
    with_attention_runtime do |_store, graph, rt|
      emit_outcome(graph, rt, "outcome.helped", "claim:1", "surface:crm", "investor_membership", "current_lps")
      supported = Chronicle::Packs::Attention.get_source_trust_fn(
        graph, "surface:crm", domain: "investor_membership", query_scope: "current_lps")
      supported["verdict"].as_s.should eq("supported")
      supported["features"].as_h.has_key?("helped").should be_true
      Chronicle::Packs::Attention.get_source_trust_fn(graph, "surface:crm", domain: "biography")["verdict"].as_s.should eq("unproven")

      emit_outcome(graph, rt, "outcome.contradicted", "claim:2", "surface:crm", "investor_membership", "current_lps")
      challenged = Chronicle::Packs::Attention.get_source_trust_fn(
        graph, "surface:crm", domain: "investor_membership", query_scope: "current_lps")
      challenged["verdict"].as_s.should eq("weak")
      challenged["evidence_refs"].as_a.size.should eq(2)
    end
  end

  it "never creates trust from a source's self-description without an outcome" do
    with_attention_runtime do |_store, graph, rt|
      graph.add_object("attention_observation", JSON.build do |json|
        json.object do
          json.field "observation_id", "source-says-trusted"
          json.field "subject_ref", "surface:web"
          json.field "subject_kind", "connector_surface"
          json.field "signal_type", "llm_judgment"
          json.field "metadata", JSON::Any.new({"source_claimed_trust" => JSON::Any.new(1_000)})
        end
      end)
      rt.run_until_idle
      graph.objects(type: "source_trust_vector").should be_empty
    end
  end

  it "learns thread and cross-thread person importance from an outbound conversation reply" do
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Attention.pack).should be_true
    rt.load_pack(Chronicle::Packs::Communication.pack).should be_true
    rt.run_until_idle
    begin
      thread = graph.add_object("conversation_thread", JSON.build do |json|
        json.object do
          json.field "thread_identity", "thread-identity"
          json.field "source_surface_id", "mail:owner"
          json.field "service", "fixture_mail"
          json.field "account_ref", "owner"
          json.field "provider_thread_id", "provider-thread"
          json.field "subject", "Planning"
        end
      end)
      participant = graph.add_object("conversation_participant", JSON.build do |json|
        json.object do
          json.field "participant_identity", "participant-identity"
          json.field "thread_id", thread.id
          json.field "address", "alice@example.com"
          json.field "display_name", "Alice"
          json.field "roles", JSON::Any.new(["recipient"].map { |r| JSON::Any.new(r) })
        end
      end)
      graph.patch_object(thread.id, JSON.parse(%({"participant_ids":[#{participant.id.inspect}]})).as_h.to_json)
      message = graph.add_object("conversation_message", JSON.build do |json|
        json.object do
          json.field "message_identity", "message-identity"
          json.field "thread_id", thread.id
          json.field "source_surface_id", "mail:owner"
          json.field "service", "fixture_mail"
          json.field "account_ref", "owner"
          json.field "provider_message_id", "provider-message"
          json.field "provider_revision_ref", "revision"
          json.field "sender", "owner@example.com"
          json.field "recipients", JSON::Any.new(["alice@example.com"].map { |r| JSON::Any.new(r) })
          json.field "direction", "outbound"
          json.field "message_kind", "human"
          json.field "evidence_id", "evidence:reply"
        end
      end)
      graph.patch_object(thread.id, JSON.parse(%({"message_ids":[#{message.id.inspect}],"message_count":1})).as_h.to_json)
      rt.run_until_idle

      vectors = {} of {String, String} => Hash(String, JSON::Any)
      graph.objects(type: "importance_vector").each do |obj|
        data = JSON.parse(obj.data).as_h
        vectors[{data["subject_kind"].as_s, data["subject_ref"].as_s}] = data
      end

      thread_key = {"conversation_thread", thread.id}
      vectors.has_key?(thread_key).should be_true
      vectors[thread_key]["features"].as_h.has_key?("outcome").should be_true

      person_rows = vectors.select { |(kind, _ref), _row| kind == "person" }
      person_rows.size.should eq(1)
      person_data = person_rows.values.first
      person_data["score_milli"].as_i.should be > 500

      native = Chronicle::Packs::Communication.project_conversation_native_fn(graph, "mail:owner")
      native_thread = native["threads"].as_a.first.as_h
      person_ref = person_data["subject_ref"].as_s
      native_thread["attention_refs"].as_a.map(&.as_s).should contain(person_ref)
    ensure
      Chronicle::Packs::Communication.clear_thread_registry
    end
  end
end
