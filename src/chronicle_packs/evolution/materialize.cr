require "json"
require "file_utils"

module Chronicle::Packs::Evolution
  # Materialize a proposal's artifacts into an importable pack.
  #
  # The graph stores the source (artifact objects); this module turns it
  # back into files and (in the full pipeline) a live pack object. The
  # deterministic file/hash helpers are ported here; the dynamic Python
  # import (upstream `import_pack`) is deferred — chronicle loads Crystal
  # packs through its own loader, so a candidate's files materialize to
  # disk and hash-verify here, and the load step lands with that seam.
  module Materialize
    # Reassemble {relative_path: text} from a proposal's artifacts.
    def self.proposal_files(graph : Chronicle::GraphProjection, proposal : Chronicle::GraphObject) : Hash(String, String)
      files = {} of String => String
      data = JSON.parse(proposal.data)
      (data["source_artifact_ids"]?.try(&.as_a) || [] of JSON::Any).each do |artifact_id|
        obj = graph.get_object(artifact_id.as_s)
        if obj.nil?
          raise PackError.new("missing source artifact #{artifact_id}")
        end
        odata = JSON.parse(obj.data)
        files[odata["title"].as_s] = odata["content"].as_s
      end
      files
    end

    # Write the file dict under a fresh directory; returns the pack root.
    #
    # With *pack_name*, the pack root is `<tmp>/<pack_name>/` so the
    # candidate's own fixtures can import the pack by name.
    def self.write_files(files : Hash(String, String), root : String? = nil, pack_name : String = "") : Path
      base = root ? Path.new(root) : Path.new(Dir.tempdir) / "evolution_#{Random::Secure.hex(6)}"
      if !pack_name.empty?
        base = base / pack_name
        FileUtils.mkdir_p(base)
      end
      files.each do |rel, text|
        parts = rel.split('/')
        if parts.includes?("..")
          raise PackError.new("path escapes pack root: #{rel}")
        end
        target = base
        parts.each { |part| target = target / part }
        FileUtils.mkdir_p(target.parent)
        File.write(target, text)
      end
      base
    end

    # The proposal pin: runtime bundle hash over a scratch materialization.
    def self.bundle_hash_of(files : Hash(String, String)) : String
      root = write_files(files)
      hash = Chronicle::Packs.compute_bundle_hash(root.to_s)
      FileUtils.rm_rf(root)
      hash
    end
  end
end
