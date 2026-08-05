require "json"
require "digest"
require "http/client"

module Chronicle::Packs::MemoryGateway
  # Embedder implementations for the Memory Gateway embedding seam. Ported
  # from upstream packs/memory_gateway/embedders.py. The backend defines
  # only the Embedder seam (backend.cr); this module provides the pluggable
  # implementations. Nothing here runs on import — registration is always an
  # explicit application-side call.

  # Deterministic hashing-trick embedder: token -> sha1 bucket counts.
  # No key, no network, byte-stable across runs: the embedder for fixtures
  # and tests. Texts are close iff they share tokens, but the token-bucket
  # shape gives tests meaningful overlap semantics.
  class HashEmbedder < Embedder
    getter default_model : String = "hash-256"
    getter dim : Int32

    def initialize(@dim : Int32 = 256)
    end

    def embed(texts : Array(String), model : String = "") : Array(Array(Float64))
      texts.map do |text|
        vec = Array.new(@dim, 0.0)
        text.downcase.scan(/[a-z0-9]+/) do |token_match|
          bucket = (Digest::SHA1.hexdigest(token_match[0])[0, 16].to_u64(16) % @dim).to_i
          vec[bucket] += 1.0
        end
        vec
      end
    end
  end

  # OpenAI embeddings via HTTP. Honors OPENAI_BASE_URL (proxies,
  # Azure-style gateways) and reads the key from OPENAI_API_KEY unless one
  # is passed explicitly. Errors propagate; the backend's _safe_embed
  # converts any embedder failure into a lexical fallback.
  class OpenAIEmbedder < Embedder
    # Host seam for the POST so specs never hit the network.
    class_property post_json : Proc(String, Hash(String, String), String, JSON::Any)?

    getter default_model : String
    getter api_key : String
    getter base_url : String
    getter timeout : Float64

    def initialize(model : String = "text-embedding-3-small", api_key : String? = nil, base_url : String? = nil, timeout : Float64 = 30.0)
      @default_model = model
      @api_key = api_key || ENV["OPENAI_API_KEY"]? || ""
      base = base_url || ENV["OPENAI_BASE_URL"]? || "https://api.openai.com/v1"
      @base_url = base.rstrip("/")
      @timeout = timeout
      raise Chronicle::Packs::PackError.new("OpenAIEmbedder requires an API key (OPENAI_API_KEY)") if @api_key.empty?
    end

    def embed(texts : Array(String), model : String = "") : Array(Array(Float64))
      chosen = model.empty? ? @default_model : model
      body = JSON.build do |json|
        json.object do
          json.field "model", chosen
          json.field "input", texts
        end
      end
      headers = {"Content-Type" => "application/json", "Authorization" => "Bearer #{@api_key}"}
      payload = if post = OpenAIEmbedder.post_json
                  post.call("#{@base_url}/embeddings", headers, body)
                else
                  response = HTTP::Client.post(
                    "#{@base_url}/embeddings",
                    headers: HTTP::Headers.new.tap { |acc| headers.each { |key, value| acc[key] = value } },
                    body: body,
                  )
                  JSON.parse(response.body)
                end
      data = payload["data"].as_a.sort_by!(&.["index"].as_i)
      data.map { |entry| entry["embedding"].as_a.map(&.as_f) }
    end
  end

  # Environment-driven embedder discovery for auto_configure_embedder.
  # Returns an OpenAIEmbedder when OPENAI_API_KEY is present, else None
  # (lexical recall). Must not raise.
  def self.default_embedder_factory : Embedder?
    key = ENV["OPENAI_API_KEY"]?
    return nil if key.nil? || key.empty?

    model = ENV["ACTIVEGRAPH_EMBEDDING_MODEL"]? || "text-embedding-3-small"
    begin
      OpenAIEmbedder.new(model: model, api_key: key)
    rescue
      nil
    end
  end
end
