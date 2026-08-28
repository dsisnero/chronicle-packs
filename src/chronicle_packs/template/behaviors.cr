require "json"

module Chronicle::Packs::Template
  # Behaviors for the template pack. Ported from upstream
  # packs/_template/behaviors.py.
  #
  # example_behavior — goal.created → example_object.
  #
  # Behavior rules: put descriptions in the docstring, NOT in the
  # annotation; behaviors should NOT directly call other packs' functions —
  # emit events instead.

  # Create an example_object from a goal's text (upstream example_behavior).
  @[Chronicle::Packs::Annotations::Behavior(name: "example_behavior", on: ["goal.created"], creates: ["example_object"])]
  def example_behavior(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : TemplateSettings) : Nil
    goal_text = JSON.parse(event.payload)["goal"]?.try(&.as_s?) || ""
    return if goal_text.empty?

    graph.add_object("example_object", {
      "name"        => JSON::Any.new("Example"),
      "description" => JSON::Any.new("Created from goal: #{goal_text}"),
    }.to_json, actor: "template.example_behavior")
  end
end
