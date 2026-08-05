require "json"
require "digest"

module Chronicle::Packs::ActivityNormalizer
  # Immutable replay-artifact storage and verification helpers. Ported from
  # upstream packs/activity_normalizer/replay.py.
  module Replay
    # Base class for deterministic replay failures.
    class ReplayError < Exception
    end

    # The evidence deliberately or accidentally has no replay payload.
    class ReplayUnavailableError < ReplayError
    end

    # The retained payload does not match its recorded SHA-256 identity.
    class ReplayIntegrityError < ReplayError
    end

    ARTIFACT_REF_RE     = /^artifact:\/\/sha256\/(?<prefix>[0-9a-f]{2})\/(?<digest>[0-9a-f]{64})$/
    LEGACY_REF_RE       = /^sha256:(?<digest>[0-9a-f]{64})$/
    PORTABLE_LOCATOR_RE = /^artifact-key:\/\/sha256\/(?<prefix>[0-9a-f]{2})\/(?<digest>[0-9a-f]{8}(?:\.[0-9a-f]{8}){7})$/
    SHA256_HEX_RE       = /^[0-9a-f]{64}$/

    def self.sha256_hex(payload : String | Bytes) : String
      data = payload.is_a?(String) ? payload.to_slice : payload
      Digest::SHA256.hexdigest(data)
    end

    def self.artifact_ref_for_hash(digest : String) : String
      raise ArgumentError.new("digest must be lowercase SHA-256 hex") unless SHA256_HEX_RE.matches?(digest)
      "artifact://sha256/#{digest[0, 2]}/#{digest}"
    end

    # Encode an artifact identity for passage through secret sanitizers:
    # content hashes are not credentials, but a gateway redacts long hex
    # values, so connector receipts chunk the digest and reconstruct the
    # canonical reference only at the trusted ingestion boundary.
    def self.portable_artifact_locator(digest : String) : String
      raise ArgumentError.new("digest must be lowercase SHA-256 hex") unless SHA256_HEX_RE.matches?(digest)
      chunks = (0...64).step(8).map { |index| digest[index, 8] }.join(".")
      "artifact-key://sha256/#{digest[0, 2]}/#{chunks}"
    end

    # Return the canonical artifact reference and digest for a locator.
    def self.artifact_identity_from_locator(locator : String) : {String, String}
      match = PORTABLE_LOCATOR_RE.match(locator)
      raise ReplayIntegrityError.new("invalid portable artifact locator") unless match
      digest = match["digest"].gsub(".", "")
      raise ReplayIntegrityError.new("artifact locator prefix does not match digest") unless match["prefix"] == digest[0, 2]
      {artifact_ref_for_hash(digest), digest}
    end

    def self._digest_from_ref(ref : String) : String
      if match = ARTIFACT_REF_RE.match(ref)
        digest = match["digest"]
        raise ReplayIntegrityError.new("artifact reference prefix does not match digest") unless match["prefix"] == digest[0, 2]
        return digest
      end
      if legacy = LEGACY_REF_RE.match(ref)
        return legacy["digest"]
      end
      raise ReplayIntegrityError.new("invalid replay artifact reference")
    end

    def self.artifact_path(artifact_store_dir : String, ref_or_digest : String) : String
      digest = SHA256_HEX_RE.matches?(ref_or_digest) ? ref_or_digest : _digest_from_ref(ref_or_digest)
      File.join(artifact_store_dir, "sha256", digest[0, 2], digest)
    end

    # Store payload once and return its canonical reference and bare digest.
    def self.store_replay_artifact(payload : String | Bytes, artifact_store_dir : String) : {String, String}
      data = payload.is_a?(String) ? payload.to_slice : payload
      digest = sha256_hex(data)
      path = artifact_path(artifact_store_dir, digest)
      Dir.mkdir_p(File.dirname(path))
      if File.exists?(path)
        existing = File.read(path).to_slice
        raise ReplayIntegrityError.new("existing artifact is corrupt: #{path}") unless sha256_hex(existing) == digest
      else
        temporary = File.join(File.dirname(path), ".#{digest}.tmp")
        File.write(temporary, data)
        File.rename(temporary, path)
      end
      {artifact_ref_for_hash(digest), digest}
    end

    def self.read_artifact(ref : String, expected_hash : String, artifact_store_dir : String, max_bytes : Int32) : Bytes
      digest = _digest_from_ref(ref)
      raise ReplayIntegrityError.new("artifact reference and replay hash disagree") unless digest == expected_hash
      path = artifact_path(artifact_store_dir, digest)
      raise ReplayUnavailableError.new("replay artifact is missing: #{ref}") unless File.file?(path)
      raise ReplayUnavailableError.new("replay artifact exceeds configured size bound") if File.size(path) > max_bytes
      payload = File.read(path).to_slice
      raise ReplayIntegrityError.new("replay artifact hash verification failed") unless sha256_hex(payload) == expected_hash
      payload
    end

    # Load only the retained replay payload; never dereference source_ref.
    def self.read_replay_payload(evidence : Hash(String, JSON::Any), settings : ActivityNormalizerSettings) : Bytes
      mode = evidence["replay_mode"]?.try(&.as_s?) || ""
      expected_hash = evidence["replay_payload_hash"]?.try(&.as_s?) || ""
      case mode
      when "reference_only"
        raise ReplayUnavailableError.new("reference_only evidence is not replay-complete")
      when "inline"
        payload = (evidence["replay_payload_ref"]?.try(&.as_s?) || "").encode(evidence["encoding"]?.try(&.as_s?) || settings.encoding)
        raise ReplayIntegrityError.new("inline replay payload hash verification failed") unless sha256_hex(payload) == expected_hash
        payload
      when "artifact"
        read_artifact(
          evidence["replay_payload_ref"]?.try(&.as_s?) || "",
          expected_hash,
          settings.artifact_store_dir,
          max_bytes: settings.max_replay_payload_bytes,
        )
      else
        raise ReplayUnavailableError.new("unsupported replay mode: #{mode.inspect}")
      end
    end
  end
end
