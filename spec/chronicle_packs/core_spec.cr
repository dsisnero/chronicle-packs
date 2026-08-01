require "spec"
require "../spec_helper"

# Core pack (packs/core): 7 object types, 7 relation types, and the three
# deterministic behaviors. Ported from upstream packs/core/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). The manifest-declared surface
# must match the live pack; behaviors must run with no LLM or API key.

module CoreSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def core_manifest : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "core" / "manifest.toml"
  end

  def core_pack_dir : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "core"
  end

  def with_core_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    yield store, graph, rt
  end
end

include CoreSpecSupport

describe Chronicle::Packs::Core do
  describe "manifest-declared surface" do
    it "matches the upstream core manifest" do
      pack = Chronicle::Packs::Core.pack
      pack.name.should eq("core")
      pack.version.should eq("0.1.2")
      pack.object_types.map(&.name).should eq(
        ["source", "observation", "task", "action", "artifact", "memory_candidate", "evaluation"]
      )
      pack.relation_types.map(&.name).should eq(
        ["grounds", "produces", "executes", "generates", "proposes", "evaluates", "derived_from", "derived_from_source"]
      )
      pack.behaviors.map(&.name).should eq(
        ["observation_extractor", "task_linker", "memory_candidate_proposer"]
      )
      pack.tools.should be_empty
      pack.settings_schema.should eq("CoreSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(core_manifest.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Core.pack)
      manifest.fixtures_entrypoint.should eq("fixtures/run_fixtures.py")
      manifest.fixtures_deterministic?.should be_true
      File.exists?((core_pack_dir / manifest.fixtures_entrypoint).to_s).should be_true
    end

    it "registers the core pack in the discovery registry" do
      pack = Chronicle::Packs.load_by_name("core")
      pack.name.should eq("core")
    end
  end

  describe "observation_extractor" do
    it "extracts observations from a new source" do
      with_core_runtime do |_store, graph, rt|
        graph.add_object("source", %({"kind":"chat_message","content":"I really prefer using JWT tokens rather than sessions. We should ship this week.","channel":"chat"}))
        rt.run_until_idle

        observations = graph.objects(type: "observation")
        observations.size.should eq(2)
        texts = observations.map { |o| JSON.parse(o.data)["text"].as_s }
        texts.should contain("I really prefer using JWT tokens rather than sessions.")
        texts.should contain("We should ship this week.")
      end
    end

    it "marks confidence and infers categories deterministically" do
      with_core_runtime do |_store, graph, rt|
        graph.add_object("source", %({"kind":"file","content":"I prefer dark mode. That is a critical requirement.","frame_id":"f1"}))
        rt.run_until_idle

        observations = graph.objects(type: "observation")
        observations.size.should eq(2)
        parsed = observations.map { |o| JSON.parse(o.data) }
        by_text = parsed.to_h { |d| {d["text"].as_s, d} }

        pref = by_text["I prefer dark mode."]
        pref.should_not be_nil
        pref["category"].as_s.should eq("preference")
        pref["confidence"].as_f.should eq(1.0)
        pref["low_confidence"].as_bool.should be_false
        pref["frame_id"].as_s.should eq("f1")
        pref["source_ids"].as_a.map(&.as_s).should_not be_empty

        req = by_text["That is a critical requirement."]
        req["category"].as_s.should eq("instruction")
      end
    end

    it "creates grounds relations from source to observation" do
      with_core_runtime do |_store, graph, rt|
        source = graph.add_object("source", %({"kind":"url","content":"The team agreed to adopt event sourcing.","url":"https://example.com"}))
        rt.run_until_idle

        obs_ids = graph.objects(type: "observation").map(&.id)
        grounds = graph.relations(source: source.id, type: "grounds")
        grounds.map(&.to_id).should eq(obs_ids)
      end
    end

    it "skips sources without content" do
      with_core_runtime do |_store, graph, _rt|
        graph.add_object("source", %({"kind":"file","content":""}))
        graph.objects(type: "observation").should be_empty
      end
    end
  end

  describe "task_linker" do
    it "links an observation to an open task by word overlap" do
      with_core_runtime do |_store, graph, rt|
        graph.add_object("task", %({"title":"Implement JWT authentication","status":"active"}))
        graph.add_object("source", %({"kind":"chat_message","content":"We should implement JWT authentication this week.","channel":"chat"}))
        rt.run_until_idle

        observations = graph.objects(type: "observation")
        observations.size.should eq(1)
        obs = observations.first
        produces = graph.relations(source: obs.id, type: "produces")
        produces.size.should eq(1)
        JSON.parse(graph.get_object(produces.first.to_id).not_nil!.data)["title"].as_s.should eq("Implement JWT authentication")
      end
    end

    it "does not link to closed tasks" do
      with_core_runtime do |_store, graph, rt|
        graph.add_object("task", %({"title":"Implement JWT authentication","status":"done"}))
        graph.add_object("source", %({"kind":"chat_message","content":"We should implement JWT authentication this week.","channel":"chat"}))
        rt.run_until_idle

        observations = graph.objects(type: "observation")
        graph.relations(type: "produces").should be_empty
      end
    end
  end

  describe "memory_candidate_proposer" do
    it "proposes a candidate for a durable high-confidence observation" do
      with_core_runtime do |_store, graph, rt|
        graph.add_object("source", %({"kind":"chat_message","content":"I prefer using JWT tokens rather than sessions.","channel":"chat"}))
        rt.run_until_idle

        candidates = graph.objects(type: "memory_candidate")
        candidates.size.should eq(1)
        data = JSON.parse(candidates.first.data)
        data["category"].as_s.should eq("preference")
        data["accepted"].as_bool.should be_false
        data["observation_ids"].as_a.size.should eq(1)

        proposes = graph.relations(source: data["observation_ids"].as_a.first.as_s, type: "proposes")
        proposes.map(&.to_id).should eq([candidates.first.id])
      end
    end

    it "respects auto_accept_memory_candidates" do
      store, graph, rt = PackSpecRuntime.runtime
      rt.load_pack(Chronicle::Packs::Core.pack, {"auto_accept_memory_candidates" => JSON::Any.new(true)})
      graph.add_object("source", %({"kind":"chat_message","content":"I prefer using JWT tokens rather than sessions.","channel":"chat"}))
      rt.run_until_idle

      candidates = graph.objects(type: "memory_candidate")
      candidates.size.should eq(1)
      JSON.parse(candidates.first.data)["accepted"].as_bool.should be_true
    end

    it "skips non-durable categories and low-confidence observations" do
      with_core_runtime do |_store, graph, rt|
        graph.add_object("source", %({"kind":"chat_message","content":"Can you make sure it handles expired tokens gracefully?","channel":"chat"}))
        rt.run_until_idle

        graph.objects(type: "memory_candidate").should be_empty
      end
    end
  end
end
