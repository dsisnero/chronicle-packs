require "yaml"
require "json"
require "chronicle"

module Chronicle::Packs
  # Deterministic fixture runner pattern (Tier 0): runs a YAML fixture
  # scenario against a runtime with its pack already loaded and asserts the
  # expected_outputs section. Ported from upstream
  # packs/core/fixtures/run_fixtures.py (_run_fixture); all scenarios run
  # without an LLM or API key.
  module FixtureRunner
    extend self

    # Run one scenario and return {passed, failures}. `graph` and `rt`
    # must be wired to the same event store, and the scenario's pack must
    # already be loaded on `rt`.
    def run_scenario(scenario : YAML::Any, graph : Chronicle::GraphProjection, rt) : {Bool, Array(String)}
      failures = [] of String
      created_ids = {} of String => Array(String)

      # Create all declared objects; behaviors fire reactively as objects
      # are added, then run_until_idle drains the cascade.
      (scenario["objects"]?.try(&.as_a?) || [] of YAML::Any).each do |obj_spec|
        type = obj_spec["type"].as_s
        data = obj_spec["data"].to_json
        obj = graph.add_object(type, data)
        (created_ids[type] ||= [] of String) << obj.id
      end

      rt.run_until_idle

      # Create explicitly declared relations after behaviors have run, so
      # behavior-created objects are available.
      (scenario["relations"]?.try(&.as_a?) || [] of YAML::Any).each do |rel_spec|
        rel_type = rel_spec["type"].as_s
        src_id = resolve_ref(rel_spec["source"]?.try(&.as_s?) || "", created_ids)
        tgt_id = resolve_ref(rel_spec["target"]?.try(&.as_s?) || "", created_ids)
        if src_id && tgt_id
          begin
            graph.add_relation(src_id, tgt_id, rel_type)
          rescue ex
            failures << "  Failed to create relation #{rel_type}: #{ex.message}"
          end
        end
      end

      rt.run_until_idle

      if expected = scenario["expected_outputs"]?
        check_observations(expected, graph, failures)
        check_memory_candidates(expected, graph, failures)
        check_artifacts(expected, graph, failures)
        check_relations(expected, graph, failures)
      end

      {failures.empty?, failures}
    end

    # Resolve a "type[index]" reference like "artifact[0]" to an object ID.
    def resolve_ref(ref : String, created_ids : Hash(String, Array(String))) : String?
      if i = ref.index('[')
        type = ref[0...i]
        index = ref[(i + 1)...].try(&.rstrip(']')).try(&.to_i?)
        if list = created_ids[type]?
          return list[index]? if index
        end
      end
      nil
    end

    # ---- expected_outputs assertions -------------------------------------

    private def check_observations(expected : YAML::Any, graph : Chronicle::GraphProjection, failures : Array(String)) : Nil
      exp = expected["observations"]?
      return if exp.nil?

      actual = graph.objects(type: "observation")
      count = actual.size

      min = exp["min_count"]?
      failures << "  observations: expected >= #{min.as_i}, got #{count}" if min && count < min.as_i

      max = exp["max_count"]?
      failures << "  observations: expected <= #{max.as_i}, got #{count}" if max && count > max.as_i

      with_field = exp["at_least_one_with"]?
      if with_field
        with_field.as_h.each do |field_any, value|
          matches = actual.any? { |object| JSON.parse(object.data)[field_any.as_s]?.try(&.raw) == value.raw }
          unless matches
            actual_vals = actual.map { |object| JSON.parse(object.data)[field_any.as_s]? }
            failures << "  observations: expected at least one with #{field_any.as_s}=#{value.raw.inspect}; actual #{field_any.as_s} values: #{actual_vals.inspect}"
          end
        end
      end
    end

    private def check_memory_candidates(expected : YAML::Any, graph : Chronicle::GraphProjection, failures : Array(String)) : Nil
      exp = expected["memory_candidates"]?
      return if exp.nil?

      actual = graph.objects(type: "memory_candidate")
      min = exp["min_count"]?
      failures << "  memory_candidates: expected >= #{min.as_i}, got #{actual.size}" if min && actual.size < min.as_i

      each = exp["each_has"]?
      if each
        each.as_a.each do |field_any|
          missing = actual.reject { |candidate| JSON.parse(candidate.data)[field_any.as_s]? }
          unless missing.empty?
            failures << "  memory_candidates: #{missing.size} object(s) missing field '#{field_any.as_s}'"
          end
        end
      end
    end

    private def check_artifacts(expected : YAML::Any, graph : Chronicle::GraphProjection, failures : Array(String)) : Nil
      exp = expected["artifacts"]?
      return if exp.nil?

      actual = graph.objects(type: "artifact")
      count = exp["count"]?
      failures << "  artifacts: expected #{count.as_i}, got #{actual.size}" if count && actual.size != count.as_i
    end

    private def check_relations(expected : YAML::Any, graph : Chronicle::GraphProjection, failures : Array(String)) : Nil
      exp = expected["relations"]?
      return if exp.nil?

      includes = exp["includes"]?
      if includes
        present = graph.relations.map(&.type).to_set
        includes.as_a.each do |rel_spec|
          rtype = rel_spec["type"].as_s
          unless present.includes?(rtype)
            desc = rel_spec["description"]?.try(&.as_s?) || ""
            failures << "  relations: expected '#{rtype}' (#{desc}), not found. Present relation types: #{present.to_a.sort.inspect}"
          end
        end
      end
    end
  end
end
