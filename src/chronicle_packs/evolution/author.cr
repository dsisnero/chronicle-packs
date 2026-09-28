module Chronicle::Packs::Evolution
  # The keyless author boundary. A drafting host may return only the four
  # reviewed Crystal source bodies; pack identity, manifest, provenance,
  # fixtures, and activation stay pack-owned. This is deliberately a pure
  # contract: no provider, credentials, graph, or gateway capability crosses
  # into the author implementation.
  record AuthoredSource,
    object_types_src : String,
    behaviors_src : String,
    settings_src : String,
    tools_src : String

  class AuthorRefusal < PackError
  end

  abstract class AuthorService
    abstract def draft(frame : Hash(String, JSON::Any)) : AuthoredSource
  end

  # The author remains a host-owned implementation, scoped to exactly one
  # graph. The pack supplies only a reviewed pure-data frame and receives
  # source bodies back; it neither configures a provider nor creates a
  # proposal from this boundary.
  module Author
    IN_FLIGHT_STATES = Set{"drafted", "gated", "trialed", "pending_approval", "adopting", "conflict", "suspended"}

    record DraftResult,
      drafting_context_id : String,
      source : AuthoredSource

    class_property services : Hash(Chronicle::GraphProjection, AuthorService) = {} of Chronicle::GraphProjection => AuthorService

    def self.set_service(graph : Chronicle::GraphProjection, service : AuthorService) : Nil
      self.services[graph] = service
    end

    def self.clear_services : Nil
      self.services.clear
    end

    def self.draft(graph : Chronicle::GraphProjection, frame : Hash(String, JSON::Any)) : AuthoredSource
      service = self.services[graph]?
      raise AuthorRefusal.new("Crystal candidate author requires a host-bound keyless AuthorService") if service.nil?
      service.draft(frame)
    end

    # Pack-owned wrapping turns the only four authorable bodies into the
    # complete Crystal candidate surface. Identity, provenance, entrypoint,
    # and the manifest are never accepted from the author.
    def self.wrap_source(source : AuthoredSource, pack_name : String) : Hash(String, String)
      unless pack_name.matches?(Chronicle::Packs::MANIFEST_NAME_RE)
        raise AuthorRefusal.new("candidate pack name #{pack_name.inspect} is not a valid manifest identifier")
      end

      files = {
        "object_types.cr" => source.object_types_src,
        "behaviors.cr"    => source.behaviors_src,
        "settings.cr"     => source.settings_src,
        "tools.cr"        => source.tools_src,
        "pack.cr"         => _pack_entrypoint(pack_name),
        "entrypoint.cr"   => _sandbox_entrypoint(pack_name),
      }
      surface = begin
        Analysis.extract_crystal_declared_surface(files)
      rescue ex : ArgumentError
        raise AuthorRefusal.new(ex.message || "authored Crystal source could not be analyzed")
      end
      files["manifest.toml"] = _manifest(pack_name, surface, Materialize.content_hash_of(files))
      files
    end

    # Seal the graph-owned record before the host author sees its pure frame.
    # This deliberately stops after drafting: deterministic pack wrapping and
    # proposal submission remain separate governance phases.
    def self.draft_for_gap(
      graph : Chronicle::GraphProjection,
      gap_id : String,
      *,
      model : String = "host:keyless",
      settings : EvolutionSettings = EvolutionSettings.new,
      day : String,
      at : String,
      approver_roles : Array(String) = ["owner", "admin"],
    ) : DraftResult
      if _proposal_in_flight_for_gap?(graph, gap_id)
        raise AuthorRefusal.new("a proposal for gap #{gap_id.inspect} is already in flight; one draft per gap at a time")
      end
      if _drafts_today(graph, day) >= settings.max_drafts_per_day
        raise AuthorRefusal.new("daily draft cap reached (#{settings.max_drafts_per_day}); no more drafts today")
      end
      assembly = AuthorFrame.assemble(graph, gap_id, approver_roles)
      context = graph.add_object("drafting_context", {
        "charter_hash"      => JSON::Any.new(assembly.charter_hash),
        "gap_id"            => JSON::Any.new(assembly.gap_id),
        "structured_fields" => JSON::Any.new(assembly.structured_fields.map { |entry| JSON::Any.new(entry) }),
        "surface_sources"   => JSON::Any.new(assembly.surface_sources.map { |source| JSON::Any.new(source) }),
        "owner_input_ids"   => JSON::Any.new(assembly.owner_input_ids.map { |input_id| JSON::Any.new(input_id) }),
        "injection_flags"   => JSON::Any.new(assembly.injection_flags.map { |flag| JSON::Any.new(flag) }),
        "model"             => JSON::Any.new(model),
        "day"               => JSON::Any.new(day),
        "at"                => JSON::Any.new(at),
      }.to_json, actor: "evolution.author")
      DraftResult.new(context.id, draft(graph, assembly.frame))
    end

    # The complete author path preserves the normal proposal boundary: it
    # first seals and obtains the four bodies, then pack-owned code stamps a
    # candidate identity and submits those exact bytes for ordinary gating.
    # The author cannot select its name, manifest, provenance, or submission
    # metadata.
    def self.draft_proposal(
      graph : Chronicle::GraphProjection,
      gap_id : String,
      *,
      base_name : String = "pack",
      model : String = "host:keyless",
      settings : EvolutionSettings = EvolutionSettings.new,
      day : String,
      at : String,
      approver_roles : Array(String) = ["owner", "admin"],
    ) : Chronicle::GraphObject
      result = draft_for_gap(
        graph, gap_id, model: model, settings: settings, day: day, at: at,
        approver_roles: approver_roles,
      )
      pack_name = "agent_#{base_name}"
      files = wrap_source(result.source, pack_name)
      Chronicle::Packs::Evolution.submit_proposal_fn(
        graph, pack_name: pack_name, files: files, gap_id: gap_id,
        authored_by: "llm", drafting_context_id: result.drafting_context_id,
      )
    end

    private def self._proposal_in_flight_for_gap?(graph : Chronicle::GraphProjection, gap_id : String) : Bool
      graph.objects(type: "mod_proposal").any? do |proposal|
        data = JSON.parse(proposal.data)
        data["gap_id"]?.try(&.as_s?) == gap_id && IN_FLIGHT_STATES.includes?(data["status"]?.try(&.as_s?) || "")
      end
    end

    private def self._drafts_today(graph : Chronicle::GraphProjection, day : String) : Int32
      graph.objects(type: "drafting_context").count do |record|
        JSON.parse(record.data)["day"]?.try(&.as_s?) == day
      end
    end

    private def self._pack_entrypoint(pack_name : String) : String
      module_name = pack_name.split('_').map(&.capitalize).join
      <<-CR
      require "chronicle-packs"
      require "./object_types"
      require "./behaviors"
      require "./settings"
      require "./tools"

      module #{module_name}
        include Chronicle::Packs::DSL

        pack(
          name: "#{pack_name}",
          version: "0.1.0",
          description: "Agent-authored Crystal candidate pack.",
        )
      end
      CR
    end

    # Chronicle's fresh-process sandbox loads this fixed ABI name. It aliases
    # the pack-owned module generated above; the author cannot provide or
    # replace this bridge.
    private def self._sandbox_entrypoint(pack_name : String) : String
      module_name = pack_name.split('_').map(&.capitalize).join
      <<-CR
      require "./pack"

      module Chronicle::Sandbox::CandidatePack
        PACK = #{module_name}::PACK
      end
      CR
    end

    private def self._manifest(pack_name : String, surface : Hash(String, Array(String)), content_hash : String) : String
      <<-TOML
      [pack]
      name = #{pack_name.to_json}
      version = "0.1.0"
      description = "Agent-authored Crystal candidate pack."
      license = "Apache-2.0"

      [pack.provenance]
      authors = ["keyless Crystal author"]
      authored_by = "agent"
      generator = "chronicle_packs/evolution/author.cr"
      source_url = ""

      [pack.integrity]
      content_hash = #{content_hash.to_json}

      [surface]
      object_types = #{_toml_array(surface["object_types"])}
      relation_types = #{_toml_array(surface["relation_types"])}
      behaviors = #{_toml_array(surface["behaviors"])}
      tools = #{_toml_array(surface["tools"])}
      capabilities = []
      TOML
    end

    private def self._toml_array(values : Array(String)) : String
      "[" + values.map(&.to_json).join(", ") + "]"
    end
  end
end
