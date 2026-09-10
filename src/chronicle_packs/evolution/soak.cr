require "json"
require "time"

module Chronicle::Packs::Evolution
  # Durable, provider-free accounting for the Crystal host's Evolution soak
  # driver. The host owns runtime construction and isolated candidate
  # execution; this state is deliberately just the reproducible audit ledger.
  module Soak
    class PathCount
      include JSON::Serializable

      property ok : Int32 = 0
      property anomalies : Int32 = 0

      def initialize(@ok : Int32 = 0, @anomalies : Int32 = 0)
      end
    end

    class State
      include JSON::Serializable

      property started_at : String
      property rotations : Int32
      property paths : Hash(String, PathCount)

      def initialize(scenario_paths : Array(String), @started_at : String = Time.utc.to_rfc3339, @rotations : Int32 = 0)
        @paths = scenario_paths.to_h { |path| {path, PathCount.new} }
      end

      def advance_rotation : Nil
        @rotations += 1
      end

      def record(path : String, passed : Bool) : Nil
        count = @paths[path]? || raise PackError.new("unknown Evolution soak scenario #{path.inspect}")
        passed ? count.ok += 1 : count.anomalies += 1
      end

      def target_met?(min_per_path : Int32) : Bool
        @paths.each_value.all? { |count| count.ok >= min_per_path }
      end

      # The portable review artifact: no host runtime, provider, or Python
      # process is needed to inspect whether every scenario has met its bar.
      def to_markdown(min_per_path : Int32) : String
        lines = ["# Evolution soak digest", "", "Rotations: #{@rotations}", "", "| Scenario | OK | Anomalies | Target |", "| --- | ---: | ---: | --- |"]
        @paths.keys.sort!.each do |path|
          count = @paths[path]
          status = count.ok >= min_per_path ? "met" : "pending"
          lines << "| #{path} | #{count.ok} | #{count.anomalies} | #{status} |"
        end
        lines << ""
        lines << "Overall: #{target_met?(min_per_path: min_per_path) ? "met" : "pending"}"
        lines.join("\n") + "\n"
      end

      def save(path : String) : Nil
        File.write(path, to_json)
      end

      def self.load(path : String, scenario_paths : Array(String)) : State
        return new(scenario_paths) unless File.exists?(path)
        state = from_json(File.read(path))
        scenario_paths.each { |scenario| state.paths[scenario] ||= PathCount.new }
        state
      end
    end
  end
end
