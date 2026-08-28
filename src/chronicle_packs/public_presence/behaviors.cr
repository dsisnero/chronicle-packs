require "json"
require "digest"
require "file_utils"

module Chronicle::Packs::PublicPresence
  # Land executed presence fetches as evidence — through the injection
  # posture. Ported from upstream
  # packs/importers/public_presence/behaviors.py.
  #
  # Fires on the gateway's capability_result; only results whose call carries
  # our `public_presence` metadata are acquired. Fetched content is untrusted
  # external content (ADR 0023): it is injection-scanned and the labels
  # travel in the normalized metadata; downstream it can become annotations
  # and candidates, never actions.

  # One executed presence fetch → one strict normalizer handoff.
  @[Chronicle::Packs::Annotations::Behavior(name: "acquire_presence_result", on: ["object.created"], where: {"type" => "capability_result"}, creates: ["acquired_item", "acquired_content", "ingestion_failure"])]
  # ameba:disable Metrics/CyclomaticComplexity -- faithful port of upstream acquire_presence_result
  def acquire_presence_result(event : Chronicle::Event, graph : Chronicle::GraphProjection, _ctx : Chronicle::Packs::BehaviorContext, settings : PublicPresenceSettings) : Nil
    payload = JSON.parse(event.payload).as_h
    result_data = payload["data"]?.try(&.as_h) || {} of String => JSON::Any
    call_id = result_data["call_id"]?.try(&.as_s?)
    call = call_id ? graph.get_object(call_id) : nil
    return if call.nil?
    call_data = JSON.parse(call.data).as_h
    presence_meta = if meta = call_data["metadata"]?.try(&.as_h)
                      meta["public_presence"]?.try(&.as_h)
                    else
                      nil
                    end
    return if presence_meta.nil?

    surface_id = presence_meta["source_surface_id"]?.try(&.as_s?) || "public_presence"
    url = presence_meta["url"]?.try(&.as_s?) || ""

    _record_fetch_failure = ->(error_code : String, message : String) {
      graph.add_object("ingestion_failure", {
        "source_surface_id" => JSON::Any.new(surface_id),
        "acquired_item_id"  => JSON::Any.new(nil),
        "source_ref"        => JSON::Any.new(url.empty? ? "#{ToolConstants::IMPORTER_ID}:unknown" : url),
        "stage"             => JSON::Any.new("acquisition"),
        "error_code"        => JSON::Any.new(error_code),
        "message"           => JSON::Any.new(message[0, 500]),
        "importer_id"       => JSON::Any.new(ToolConstants::IMPORTER_ID),
        "importer_version"  => JSON::Any.new(ToolConstants::IMPORTER_VERSION),
        "extractor_id"      => JSON::Any.new(nil),
        "extractor_version" => JSON::Any.new(nil),
        "recoverable"       => JSON::Any.new(true),
        "metadata"          => JSON::Any.new({"call_id" => JSON::Any.new(call_id)}),
      }.to_json, actor: "public_presence.acquire")
    }

    unless result_data["success"]?.try(&.raw) == true
      _record_fetch_failure.call("fetch_failed", result_data["error"]?.try(&.as_s?) || "capability failed")
      return
    end
    output = begin
      JSON.parse(result_data["output_data"]?.try(&.as_s?) || "{}").as_h
    rescue ex : JSON::ParseException
      _record_fetch_failure.call("malformed_fetch_output", "JSONDecodeError: #{ex.message}")
      return
    end
    text = output["text"]?.try(&.as_s?) || ""
    if text.strip.empty?
      _record_fetch_failure.call("empty_page", "no text extracted from #{url}")
      return
    end

    text = text[0, settings.max_page_chars]
    injection_flags = ToolGateway::Untrusted.scan_for_injection(text)
    replay_unit = _canonical_json(JSON::Any.new({
      "url"       => JSON::Any.new(url),
      "final_url" => output["final_url"]? || JSON::Any.new(nil),
      "status"    => output["status"]? || JSON::Any.new(nil),
      "title"     => output["title"]? || JSON::Any.new(nil),
      "text"      => JSON::Any.new(text),
    }))
    replay_ref, replay_hash = _artifact_ref(replay_unit.to_slice, settings.artifact_store_dir)

    item = graph.add_object("acquired_item", {
      "source_surface_id"   => JSON::Any.new(surface_id),
      "provider_item_id"    => JSON::Any.new(url),
      "dedup_key"           => JSON::Any.new("presence:#{url}"),
      "source_ref"          => JSON::Any.new(url),
      "source_hash"         => JSON::Any.new(Digest::SHA256.hexdigest(text)),
      "provider_time"       => result_data["executed_at"]? || JSON::Any.new(nil),
      "replay_mode"         => JSON::Any.new("artifact"),
      "replay_payload_ref"  => JSON::Any.new(replay_ref),
      "replay_payload_hash" => JSON::Any.new(replay_hash),
      "media_type"          => JSON::Any.new("text/plain"),
      "importer_id"         => JSON::Any.new(ToolConstants::IMPORTER_ID),
      "importer_version"    => JSON::Any.new(ToolConstants::IMPORTER_VERSION),
    }.to_json, actor: "public_presence.acquire")
    original_chars = (output["text"]?.try(&.as_s?) || "").size
    truncated = (output["truncated"]?.try(&.as_bool?) || false) || original_chars > settings.max_page_chars
    graph.add_object("acquired_content", {
      "acquired_item_id"    => JSON::Any.new(item.id),
      "normalized_content"  => JSON::Any.new(text),
      "normalized_metadata" => JSON::Any.new({
        "subject_scope"    => JSON::Any.new("owner_profile"),
        "source_trust"     => JSON::Any.new("unverified_public"),
        "memory_admission" => JSON::Any.new("review_required"),
        "url"              => JSON::Any.new(url),
        "final_url"        => output["final_url"]? || JSON::Any.new(nil),
        "status"           => output["status"]? || JSON::Any.new(nil),
        "title"            => output["title"]? || JSON::Any.new(nil),
        "handle_kind"      => presence_meta["handle_kind"]? || JSON::Any.new(nil),
        "run_id"           => presence_meta["run_id"]? || JSON::Any.new(nil),
        "injection_flags"  => JSON::Any.new(injection_flags.map { |flag| JSON::Any.new(flag) }),
        "truncated"        => JSON::Any.new(truncated),
      }),
      "source_category" => JSON::Any.new("local_knowledge"),
      "connection_path" => JSON::Any.new("pack"),
      "is_fixture"      => JSON::Any.new(presence_meta["is_fixture"]?.try(&.as_bool?) || false),
    }.to_json, actor: "public_presence.acquire")
  end
end
