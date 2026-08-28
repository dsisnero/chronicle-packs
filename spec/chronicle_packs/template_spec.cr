require "spec"
require "../spec_helper"

# Template Pack (packs/_template): the pack-authoring template — the
# canonical example of the scaffolding convention (settings, object_types,
# relation_types, behaviors, tools, fixtures). Translated from upstream
# packs/_template/* (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# The template has no real upstream manifest (its manifest.toml is a
# skeleton with a REGENERATE-ME hash), so the surface is verified against
# the upstream __init__/object_types/behaviors/settings declarations rather
# than a pinned manifest hash.

module TemplateSpecSupport
  extend self

  def with_template_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    settings = Chronicle::Packs::Template::TemplateSettings.new
    rt.load_pack(Chronicle::Packs::Template.pack, JSON.parse(settings.to_json).as_h).should be_true
    yield store, graph, rt
  end
end

include TemplateSpecSupport

describe Chronicle::Packs::Template do
  describe "manifest-declared surface" do
    it "matches the upstream template declarations" do
      pack = Chronicle::Packs::Template.pack
      pack.name.should eq("template")
      pack.version.should eq("0.1.0")
      pack.object_types.map(&.name).should eq(["example_object"])
      pack.relation_types.map(&.name).should eq([] of String)
      pack.behaviors.map(&.name).should eq(["example_behavior"])
      pack.tools.map(&.name).should eq([] of String)
      pack.settings_schema.should eq("TemplateSettings")
    end

    it "declares TemplateSettings with the upstream defaults" do
      s = Chronicle::Packs::Template::TemplateSettings.new
      s.enabled?.should be_true
      s.max_objects_per_run.should eq(100)
    end
  end

  describe "example_behavior" do
    it "creates an example_object from a non-empty goal text" do
      with_template_runtime do |_store, graph, rt|
        graph.emit(Chronicle::Event.new(
          schema_version: 1_u16, sequence: 1_u64, id: "goal_created_1",
          type: "goal.created", actor: "user", caused_by: nil,
          payload: %({"goal":"make a greeting"}),
        ))
        rt.run_until_idle
        objects = graph.objects(type: "example_object")
        objects.size.should eq(1)
        data = JSON.parse(objects.first.data)
        data["name"].as_s.should eq("Example")
        data["description"].as_s.should eq("Created from goal: make a greeting")
      end
    end

    it "creates nothing when the goal text is empty" do
      with_template_runtime do |_store, graph, rt|
        graph.emit(Chronicle::Event.new(
          schema_version: 1_u16, sequence: 1_u64, id: "goal_created_1",
          type: "goal.created", actor: "user", caused_by: nil,
          payload: %({"goal":""}),
        ))
        rt.run_until_idle
        graph.objects(type: "example_object").size.should eq(0)
      end
    end
  end
end
