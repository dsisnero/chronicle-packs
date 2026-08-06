require "json"

module Chronicle::Packs::SemanticExtraction
  # The recorded structured-completion boundary the pack depends on. Crig
  # supplies the LLM transport; Chronicle owns the durable/replayable model
  # call; the extractor receives a recorded completion and never touches a
  # provider directly. `operation` and causation ride in metadata.
  abstract class RecordedCompletion
    getter model : String = ""
    getter prompt_version : String = ""

    abstract def structured(input : String, idempotency_key : String, metadata : Hash(String, JSON::Any)) : String
  end

  # Reference recorded implementation: emits durable llm.requested /
  # llm.responded events on the bound graph and replays a prior response by
  # idempotency key — zero provider contact on replay, surviving rebuilds.
  class RecordedCompletionService < RecordedCompletion
    getter graph : Chronicle::GraphProjection
    getter model : String
    getter prompt_version : String
    getter provider : Proc(String, String, String)?

    def initialize(@graph : Chronicle::GraphProjection, @model : String, @provider : Proc(String, String, String)?, @prompt_version : String = "1")
    end

    def structured(input : String, idempotency_key : String, metadata : Hash(String, JSON::Any)) : String
      unless idempotency_key.empty?
        if replayed = _replay(idempotency_key)
          return replayed
        end
      end

      live = provider
      raise Chronicle::Packs::PackError.new("semantic.llm needs a live provider or a recorded response to replay from (zero-key mode uses the deterministic extractor only)") if live.nil?

      _emit_requested(input, idempotency_key, metadata)
      response = live.call(@model, input)
      _emit_responded(idempotency_key, response)
      response
    end

    private def _replay(idempotency_key : String) : String?
      graph.events.reverse_each do |event|
        next unless event.type == "llm.responded"

        payload = JSON.parse(event.payload).as_h
        next unless payload["idempotency_key"]?.try(&.as_s?) == idempotency_key

        return payload["output"]?.try(&.as_s?) || ""
      end
      nil
    end

    private def _emit_requested(input : String, idempotency_key : String, metadata : Hash(String, JSON::Any)) : Nil
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16,
        sequence: graph.events.size.to_u64 + 1,
        id: "llm_req_#{graph.events.size + 1}",
        type: "llm.requested",
        actor: "semantic_extraction",
        caused_by: nil,
        payload: {"operation" => JSON::Any.new("semantic_annotation_extraction"), "model" => JSON::Any.new(@model), "prompt_version" => JSON::Any.new(@prompt_version), "idempotency_key" => JSON::Any.new(idempotency_key), "metadata" => JSON::Any.new(metadata)}.to_json,
      ))
    end

    private def _emit_responded(idempotency_key : String, output : String) : Nil
      graph.emit(Chronicle::Event.new(
        schema_version: 1_u16,
        sequence: graph.events.size.to_u64 + 1,
        id: "llm_resp_#{graph.events.size + 1}",
        type: "llm.responded",
        actor: "semantic_extraction",
        caused_by: nil,
        payload: {"operation" => JSON::Any.new("semantic_annotation_extraction"), "model" => JSON::Any.new(@model), "idempotency_key" => JSON::Any.new(idempotency_key), "output" => JSON::Any.new(output)}.to_json,
      ))
    end
  end
end
