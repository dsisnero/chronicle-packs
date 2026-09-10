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
end
