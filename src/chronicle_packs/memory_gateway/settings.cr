require "json"

module Chronicle::Packs::MemoryGateway
  # Configuration for Memory Gateway Pack. Ported from upstream
  # packs/memory_gateway/settings.py.
  struct MemoryGatewaySettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter acceptance_threshold : Float64 = 0.6
    getter max_items : Int32 = 1000
    getter backend_url : String = ":memory:"
    getter retrieval_top_k : Int32 = 10
    getter min_retrieval_score : Float64 = 0.2
    getter auto_accept_categories : Array(String) = ["preference", "instruction", "decision"]
    getter auto_accept_min_confidence : Float64 = 0.5
    getter provenance_admission : String = "trusted_senders"
    getter evidence_floor_min_score : Float64 = 0.2

    def initialize(
      @acceptance_threshold : Float64 = 0.6,
      @max_items : Int32 = 1000,
      @backend_url : String = ":memory:",
      @retrieval_top_k : Int32 = 10,
      @min_retrieval_score : Float64 = 0.2,
      @auto_accept_categories : Array(String) = ["preference", "instruction", "decision"],
      @auto_accept_min_confidence : Float64 = 0.5,
      @provenance_admission : String = "trusted_senders",
      @evidence_floor_min_score : Float64 = 0.2,
    )
    end
  end
end
