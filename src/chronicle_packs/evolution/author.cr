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

    # Seal the graph-owned record before the host author sees its pure frame.
    # This deliberately stops after drafting: deterministic pack wrapping and
    # proposal submission remain separate governance phases.
    def self.draft_for_gap(
      graph : Chronicle::GraphProjection,
      gap_id : String,
      *,
      model : String = "host:keyless",
      day : String,
      at : String,
      approver_roles : Array(String) = ["owner", "admin"],
    ) : DraftResult
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
  end
end
