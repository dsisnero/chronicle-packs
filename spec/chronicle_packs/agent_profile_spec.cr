require "spec"
require "../spec_helper"

# Agent Profile pack (packs/agent_profile): the assistant's identity, goals,
# personality, and standing instructions scoped by channel/audience. Ported
# from upstream packs/agent_profile/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). Deterministic, no API key.

module AgentProfileSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def agent_profile_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "agent_profile" / "manifest.toml"
  end

  def profile_settings(json : String) : Chronicle::Packs::AgentProfile::AgentProfileSettings
    Chronicle::Packs::AgentProfile::AgentProfileSettings.from_json(json)
  end

  def with_profile_runtime(custom_settings = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if custom_settings
      rt.load_pack(Chronicle::Packs::AgentProfile.pack, JSON.parse(custom_settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::AgentProfile.pack).should be_true
    end
    Chronicle::Packs::AgentProfile.clear_profile_registry
    yield store, graph, rt
  ensure
    Chronicle::Packs::AgentProfile.clear_profile_registry
  end

  def register_profile(graph : Chronicle::GraphProjection, name : String, mission : String = "", profile_id : String? = nil)
    data = JSON.build do |json|
      json.object do
        json.field "name", name
        json.field "mission", mission
        json.field "personality_description", ""
        json.field "owner_name", nil
        json.field "version", "1"
        json.field "active", true
        json.field "metadata", {} of String => JSON::Any
      end
    end
    obj = graph.add_object("agent_profile", data)
    obj
  end
end

include AgentProfileSpecSupport

describe Chronicle::Packs::AgentProfile do
  describe "manifest-declared surface" do
    it "matches the upstream agent_profile manifest" do
      pack = Chronicle::Packs::AgentProfile.pack
      pack.name.should eq("agent_profile")
      pack.version.should eq("0.1.1")
      pack.object_types.map(&.name).should eq(
        ["agent_profile", "goal", "standing_instruction", "personality_profile",
         "owner_preference", "profile_context_request", "profile_context_view"]
      )
      pack.relation_types.map(&.name).should eq(
        ["owns_goal", "owns_instruction", "owns_preference", "fulfilled_by_profile", "triggers_context_for"]
      )
      pack.behaviors.map(&.name).should eq(
        ["profile_registry_recorder", "goal_registry_recorder", "instruction_registry_recorder",
         "personality_registry_recorder", "preference_registry_recorder", "profile_context_trigger",
         "frame_context_trigger", "profile_context_provider"]
      )
      pack.tools.map(&.name).should eq(["register_profile", "request_profile_context"])
      pack.settings_schema.should eq("AgentProfileSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(agent_profile_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::AgentProfile.pack)
    end
  end

  describe "profile_context_provider" do
    it "assembles a scoped context view from a request" do
      with_profile_runtime do |_store, graph, rt|
        profile = register_profile(graph, "Clarity", "Serve the owner.")
        rt.run_until_idle
        profile_id = profile.id

        # Goals, instructions, personality, preferences for the profile.
        graph.add_object("goal", JSON.build do |json|
          json.object do
            json.field "text", "Grow revenue"
            json.field "priority", "high"
            json.field "status", "active"
            json.field "profile_id", profile_id
          end
        end)
        graph.add_object("standing_instruction", JSON.build do |json|
          json.object do
            json.field "text", "Be concise with investors"
            json.field "scope", "communication"
            json.field "applies_to_audience_role", "external"
            json.field "priority", 90
            json.field "profile_id", profile_id
          end
        end)
        graph.add_object("standing_instruction", JSON.build do |json|
          json.object do
            json.field "text", "Always reply in the user's language"
            json.field "scope", "global"
            json.field "priority", 50
            json.field "profile_id", profile_id
          end
        end)
        graph.add_object("personality_profile", JSON.build do |json|
          json.object do
            json.field "tone", "direct"
            json.field "verbosity", "concise"
            json.field "formality", "informal"
            json.field "applies_to_channel", "email"
            json.field "profile_id", profile_id
          end
        end)
        graph.add_object("owner_preference", JSON.build do |json|
          json.object do
            json.field "key", "preferred_language"
            json.field "value", "Spanish"
            json.field "profile_id", profile_id
          end
        end)
        rt.run_until_idle

        # Request an owner-facing context on chat.
        graph.add_object("profile_context_request", JSON.build do |json|
          json.object do
            json.field "profile_id", profile_id
            json.field "channel", "chat"
            json.field "audience_role", "owner"
          end
        end)
        rt.run_until_idle

        views = graph.objects(type: "profile_context_view")
        views.size.should eq(1)
        data = JSON.parse(views.first.data)
        data["agent_name"].as_s.should eq("Clarity")
        data["mission"].as_s.should eq("Serve the owner.")
        data["personality"].as_h["tone"].as_s.should eq("neutral") # chat != email -> default
        data["active_goals"].as_a.map { |g| g["text"].as_s }.should eq(["Grow revenue"])
        data["standing_instructions"].as_a.map(&.as_s).should eq(["Always reply in the user's language"])
        data["owner_preferences"].as_h["preferred_language"].as_s.should eq("Spanish")

        request = graph.objects(type: "profile_context_request").first
        graph.relations(source: request.id, type: "fulfilled_by_profile").map(&.to_id).should eq([views.first.id])
      end
    end

    it "suppresses mission for external audiences by default" do
      with_profile_runtime do |_store, graph, rt|
        profile = register_profile(graph, "Clarity", "Serve the owner.")
        rt.run_until_idle

        graph.add_object("profile_context_request", JSON.build do |json|
          json.object do
            json.field "profile_id", profile.id
            json.field "channel", "email"
            json.field "audience_role", "external"
          end
        end)
        rt.run_until_idle

        views = graph.objects(type: "profile_context_view")
        data = JSON.parse(views.first.data)
        data["mission"].as_s.should eq("")
      end
    end

    it "exposes mission to external audiences when configured" do
      with_profile_runtime(profile_settings(%({"expose_mission_to_external":true}))) do |_store, graph, rt|
        profile = register_profile(graph, "Clarity", "Serve the owner.")
        rt.run_until_idle

        graph.add_object("profile_context_request", JSON.build do |json|
          json.object do
            json.field "profile_id", profile.id
            json.field "audience_role", "customer"
          end
        end)
        rt.run_until_idle

        views = graph.objects(type: "profile_context_view")
        JSON.parse(views.first.data)["mission"].as_s.should eq("Serve the owner.")
      end
    end

    it "orders active goals by priority and applies the matching personality" do
      with_profile_runtime do |_store, graph, rt|
        profile = register_profile(graph, "Clarity", "Serve the owner.")
        rt.run_until_idle
        profile_id = profile.id

        {["medium", "Ship"], ["critical", "Fix outage"], ["low", "Ship low"]}.each do |(priority, text)|
          graph.add_object("goal", JSON.build do |json|
            json.object do
              json.field "text", text
              json.field "priority", priority
              json.field "status", "active"
              json.field "profile_id", profile_id
            end
          end)
        end
        graph.add_object("personality_profile", JSON.build do |json|
          json.object do
            json.field "tone", "warm"
            json.field "verbosity", "detailed"
            json.field "formality", "formal"
            json.field "applies_to_channel", "chat"
            json.field "profile_id", profile_id
          end
        end)
        rt.run_until_idle

        graph.add_object("profile_context_request", JSON.build do |json|
          json.object do
            json.field "profile_id", profile_id
            json.field "channel", "chat"
            json.field "audience_role", "owner"
          end
        end)
        rt.run_until_idle

        data = JSON.parse(graph.objects(type: "profile_context_view").first.data)
        data["active_goals"].as_a.map { |g| g["text"].as_s }.should eq(["Fix outage", "Ship", "Ship low"])
        data["personality"].as_h["tone"].as_s.should eq("warm")
        data["personality"].as_h["verbosity"].as_s.should eq("detailed")
      end
    end

    it "limits instructions by max_standing_instructions" do
      with_profile_runtime(profile_settings(%({"max_standing_instructions":1}))) do |_store, graph, rt|
        profile = register_profile(graph, "Clarity", "Serve the owner.")
        rt.run_until_idle
        profile_id = profile.id

        2.times do |i|
          graph.add_object("standing_instruction", JSON.build do |json|
            json.object do
              json.field "text", "Instruction #{i}"
              json.field "priority", 60 - i
              json.field "profile_id", profile_id
            end
          end)
        end
        rt.run_until_idle

        graph.add_object("profile_context_request", JSON.build do |json|
          json.object do
            json.field "profile_id", profile_id
          end
        end)
        rt.run_until_idle

        data = JSON.parse(graph.objects(type: "profile_context_view").first.data)
        data["standing_instructions"].as_a.map(&.as_s).should eq(["Instruction 0"])
      end
    end
  end

  describe "assemble_profile_view" do
    it "assembles a view directly without writing to the graph" do
      with_profile_runtime do |_store, graph, rt|
        profile = register_profile(graph, "Clarity", "Serve the owner.")
        rt.run_until_idle

        view = Chronicle::Packs::AgentProfile.assemble_profile_view(graph, profile_id: profile.id, audience_role: "owner")
        view.should_not be_nil
        view.not_nil!.agent_name.should eq("Clarity")
        view.not_nil!.mission.should eq("Serve the owner.")
        graph.objects(type: "profile_context_view").should be_empty
      end
    end

    it "returns nil when no profile is available" do
      with_profile_runtime do |_store, graph, _rt|
        Chronicle::Packs::AgentProfile.assemble_profile_view(graph).should be_nil
      end
    end
  end

  describe "profile_context_trigger" do
    it "auto-creates a request on auth_context.created" do
      with_profile_runtime do |_store, graph, rt|
        profile = register_profile(graph, "Clarity", "Serve the owner.")
        rt.run_until_idle

        auth = graph.add_object("auth_context", JSON.build do |json|
          json.object do
            json.field "principal_id", "p1"
            json.field "principal_role", "owner"
            json.field "channel", "chat"
          end
        end)
        rt.run_until_idle

        requests = graph.objects(type: "profile_context_request")
        requests.size.should eq(1)
        data = JSON.parse(requests.first.data)
        data["profile_id"].as_s.should eq(profile.id)
        data["audience_role"].as_s.should eq("owner")
        data["channel"].as_s.should eq("chat")

        graph.relations(source: auth.id, type: "triggers_context_for").map(&.to_id).should eq([requests.first.id])
      end
    end
  end

  describe "frame_context_trigger" do
    it "auto-creates a request on frame.created with default owner audience" do
      with_profile_runtime do |_store, graph, rt|
        profile = register_profile(graph, "Clarity", "Serve the owner.")
        rt.run_until_idle

        frame = graph.add_object("frame", JSON.build do |json|
          json.object do
            json.field "channel", "email"
            json.field "audience_role", nil
          end
        end)
        rt.run_until_idle

        requests = graph.objects(type: "profile_context_request")
        requests.size.should eq(1)
        data = JSON.parse(requests.first.data)
        data["profile_id"].as_s.should eq(profile.id)
        data["audience_role"].as_s.should eq("owner")
        data["channel"].as_s.should eq("email")

        graph.relations(source: frame.id, type: "triggers_context_for").map(&.to_id).should eq([requests.first.id])
      end
    end
  end

  describe "tools" do
    it "registers a profile and requests a context view" do
      with_profile_runtime do |_store, graph, rt|
        obj = Chronicle::Packs::AgentProfile.register_profile_fn(graph, "Clarity", "Serve the owner.", "Direct.", "Alice")
        rt.run_until_idle
        obj.type.should eq("agent_profile")
        JSON.parse(obj.data)["name"].as_s.should eq("Clarity")

        req = Chronicle::Packs::AgentProfile.request_profile_context_fn(graph, obj.id, channel: "chat", audience_role: "owner")
        rt.run_until_idle
        req.type.should eq("profile_context_request")

        views = graph.objects(type: "profile_context_view")
        views.size.should eq(1)
      end
    end
  end
end
