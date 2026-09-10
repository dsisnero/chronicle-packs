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
  end
end
