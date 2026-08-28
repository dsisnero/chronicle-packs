require "json"

module Chronicle::Packs::PublicPresence
  # The bootstrap-run ledger: every fetch planned, executed, or refused.
  # Ported from upstream packs/importers/public_presence/object_types.py
  # (PresenceBootstrapRun). The Pydantic `_StrictModel` extra="forbid" is not
  # enforced (JSON::Serializable ignores unknown fields).

  # One budgeted, fully logged public-presence bootstrap run.
  @[Chronicle::Packs::Annotations::ObjectType(name: "presence_bootstrap_run", description: "One budgeted, fully logged public-presence bootstrap run.")]
  struct PresenceBootstrapRun
    include JSON::Serializable

    getter run_identity : String
    getter source_surface_id : String
    getter handles : Hash(String, JSON::Any)
    getter planned_urls : Array(String)
    getter budget : Int32
    getter call_ids : Array(String) = [] of String
    getter skipped : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any)
    getter status : String = "proposed"
    getter? is_fixture : Bool = false
    getter requested_by : String? = nil
    getter metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(
      @run_identity : String, @source_surface_id : String,
      @handles : Hash(String, JSON::Any), @planned_urls : Array(String),
      @budget : Int32, @call_ids : Array(String) = [] of String,
      @skipped : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
      @status : String = "proposed", @is_fixture : Bool = false,
      @requested_by : String? = nil,
      @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
    )
    end
  end
end
