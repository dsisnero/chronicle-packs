require "json"

module Chronicle::Packs::PublicPresence
  # Budget, bounds, and the fetch-capability seam for public presence. Ported
  # from upstream packs/importers/public_presence/settings.py.
  struct PublicPresenceSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter artifact_store_dir : String = ".activegraph/replay-artifacts"
    getter max_fetches_per_run : Int32 = 10
    getter max_page_chars : Int32 = 32_000
    getter timeout_seconds : Float64 = 10.0
    getter fetch_provider : String = "public_presence"
    getter fetch_capability : String = "fetch_page"

    def initialize(
      @artifact_store_dir : String = ".activegraph/replay-artifacts",
      @max_fetches_per_run : Int32 = 10,
      @max_page_chars : Int32 = 32_000,
      @timeout_seconds : Float64 = 10.0,
      @fetch_provider : String = "public_presence",
      @fetch_capability : String = "fetch_page",
    )
    end
  end
end
