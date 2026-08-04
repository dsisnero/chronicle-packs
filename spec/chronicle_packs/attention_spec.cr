require "spec"
require "../spec_helper"

# Attention pack (packs/attention): semantic engagement observations and
# inspectable importance/source-trust vectors. Ported from upstream
# packs/attention/* (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# Deterministic, no API key, no pack dependencies.

module AttentionSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def attention_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "attention" / "manifest.toml"
  end

  def with_attention_runtime(custom_settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    if custom_settings
      rt.load_pack(Chronicle::Packs::Attention.pack, JSON.parse(custom_settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::Attention.pack).should be_true
    end
    yield store, graph, rt
  end

  def emit(graph : Chronicle::GraphProjection, type : String, payload : String, seq : UInt64)
    graph.emit(Chronicle::Event.new(
      schema_version: 1_u16, sequence: seq, id: "#{type.gsub('.', '_')}_#{seq}",
      type: type, actor: "spec", caused_by: nil, payload: payload
    ))
  end
end

include AttentionSpecSupport

describe Chronicle::Packs::Attention do
  describe "manifest-declared surface" do
    it "matches the upstream attention manifest" do
      pack = Chronicle::Packs::Attention.pack
      pack.name.should eq("attention")
      pack.version.should eq("0.3.0")
      pack.object_types.map(&.name).should eq(
        ["attention_observation", "interaction_batch", "importance_vector", "source_trust_vector"]
      )
      pack.relation_types.should be_empty
      pack.behaviors.map(&.name).should eq(
        ["semantic_attention_signal_capture", "importance_vector_projector", "source_trust_vector_projector"]
      )
      pack.tools.map(&.name).should eq(
        ["record_attention_observation", "record_interaction_batch", "get_importance", "get_source_trust", "rank_importance"]
      )
      pack.settings_schema.should eq("AttentionSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(attention_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Attention.pack)
    end
  end

  describe "scoring helpers" do
    it "computes importance score, confidence, and band" do
      unranked = Chronicle::Packs::Attention.importance_score(0, 0)
      unranked[2].should eq("unranked")

      supported = Chronicle::Packs::Attention.importance_score(2000, 0)
      supported[2].should eq("high")
      supported[0].should be > 650

      opposed = Chronicle::Packs::Attention.importance_score(0, 2000)
      opposed[2].should eq("low")
    end

    it "computes trust score, confidence, and verdict" do
      Chronicle::Packs::Attention.trust_score(0, 0)[2].should eq("unproven")
      Chronicle::Packs::Attention.trust_score(2000, 0)[2].should eq("supported")
      Chronicle::Packs::Attention.trust_score(0, 2000)[2].should eq("harmful")
    end
  end

  describe "semantic_attention_signal_capture" do
    it "mints attention observations from a signal event" do
      with_attention_runtime do |_store, graph, rt|
        emit(graph, "attention.signal_observed", %({"producer":"connector","observations":[
          {"observation_id":"obs_1","subject_ref":"email/msg/123","signal_type":"opened","strength_milli":1000,"source":"connector"}
        ]}), 1_u64)
        rt.run_until_idle

        observations = graph.objects(type: "attention_observation")
        observations.size.should eq(1)
        data = JSON.parse(observations.first.data)
        data["observation_id"].as_s.should eq("obs_1")
        data["subject_ref"].as_s.should eq("email/msg/123")
        data["signal_type"].as_s.should eq("opened")
        data["metadata"].as_h["producer"].as_s.should eq("connector")
      end
    end

    it "fails closed on a nonresponse_window without an opportunity" do
      with_attention_runtime do |_store, graph, rt|
        emit(graph, "attention.signal_observed", %({"observations":[
          {"observation_id":"obs_2","subject_ref":"email/msg/9","signal_type":"nonresponse_window"}
        ]}), 2_u64)
        expect_raises(Chronicle::Packs::PackError, /nonresponse_window requires opportunity_id/) do
          rt.run_until_idle
        end
      end
    end
  end

  describe "importance_vector_projector" do
    it "projects an importance vector from observations" do
      with_attention_runtime do |_store, graph, rt|
        graph.add_object("attention_observation", %({"observation_id":"obs_1","subject_ref":"email/msg/123","signal_type":"opened","strength_milli":1000,"source":"connector"}))
        rt.run_until_idle
        graph.add_object("attention_observation", %({"observation_id":"obs_2","subject_ref":"email/msg/123","signal_type":"replied","strength_milli":1000,"source":"user","explicit":true}))
        rt.run_until_idle

        vectors = graph.objects(type: "importance_vector")
        vectors.size.should eq(1)
        data = JSON.parse(vectors.first.data)
        data["subject_ref"].as_s.should eq("email/msg/123")
        data["support_milli"].as_i.should be > 0
        data["priority_band"].as_s.should eq("medium")
        data["observation_ids"].as_a.size.should eq(2)
        data["features"].as_h.keys.should contain("engagement")
        data["features"].as_h.keys.should contain("outcome")
      end
    end

    it "ignores explicit signals not marked explicit" do
      with_attention_runtime do |_store, graph, rt|
        graph.add_object("attention_observation", %({"observation_id":"obs_1","subject_ref":"email/msg/1","signal_type":"explicit_important","strength_milli":1000,"explicit":false}))
        rt.run_until_idle

        vectors = graph.objects(type: "importance_vector")
        data = JSON.parse(vectors.first.data)
        data["features"].as_h.keys.should contain("unverified_explicit")
        data["support_milli"].as_i.should eq(0)
      end
    end
  end

  describe "source_trust_vector_projector" do
    it "projects source trust from outcome events" do
      with_attention_runtime do |_store, graph, rt|
        emit(graph, "outcome.helped", %({"source_context":{"source_ref":"news/feed/1","domain":"crypto","query_scope":"general"}}), 1_u64)
        rt.run_until_idle

        vectors = graph.objects(type: "source_trust_vector")
        vectors.size.should eq(1)
        data = JSON.parse(vectors.first.data)
        data["source_ref"].as_s.should eq("news/feed/1")
        data["domain"].as_s.should eq("crypto")
        data["support_milli"].as_i.should eq(1000)
        data["verdict"].as_s.should eq("supported")
        data["outcome_event_ids"].as_a.size.should eq(1)
      end
    end
  end

  describe "tools" do
    it "records an idempotent attention observation" do
      with_attention_runtime do |_store, graph, rt|
        result = Chronicle::Packs::Attention.record_attention_observation_fn(
          graph, observation_id: "obs_1", subject_ref: "email/msg/1", signal_type: "opened"
        )
        result["created"].as_bool.should be_true
        again = Chronicle::Packs::Attention.record_attention_observation_fn(
          graph, observation_id: "obs_1", subject_ref: "email/msg/1", signal_type: "opened"
        )
        again["created"].as_bool.should be_false
      end
    end

    it "flushes a bounded interaction batch" do
      with_attention_runtime do |_store, graph, rt|
        result = Chronicle::Packs::Attention.record_interaction_batch_fn(
          graph, batch_id: "b1", session_id: "s1", batch_sequence: 0, client_id: "c1",
          observations: [{"subject_ref" => JSON::Any.new("email/msg/2"), "signal_type" => JSON::Any.new("impression")}]
        )
        result["created"].as_bool.should be_true
        graph.objects(type: "attention_observation").size.should eq(1)
        graph.objects(type: "interaction_batch").size.should eq(1)
      end
    end

    it "gets importance with a default when none is projected" do
      with_attention_runtime do |_store, graph, _rt|
        row = Chronicle::Packs::Attention.get_importance_fn(graph, "email/msg/99")
        row["score_milli"].as_i.should eq(500)
        row["priority_band"].as_s.should eq("unranked")
      end
    end

    it "ranks importance with an exploration reserve" do
      with_attention_runtime do |_store, graph, rt|
        graph.add_object("attention_observation", %({"observation_id":"obs_1","subject_ref":"a","signal_type":"completed","strength_milli":1000,"explicit":true}))
        rt.run_until_idle

        result = Chronicle::Packs::Attention.rank_importance_fn(graph, ["a", "b"], limit: 2, exploration_slots: 1)
        result["items"].as_a.size.should eq(2)
        reasons = result["items"].as_a.map { |item| item["selection_reason"].as_s }
        reasons.should contain("importance")
        reasons.should contain("exploration")
      end
    end
  end
end
