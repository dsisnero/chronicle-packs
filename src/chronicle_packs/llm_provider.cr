require "chronicle"

module Chronicle::Packs::LLMProvider
  # Packs-level LLM provider configuration. The one place packs-side code
  # learns which LLM provider is configured. Ported from upstream
  # `packs/llm_provider.py` (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
  #
  # This module only decides *which* provider is configured and *why*; it
  # never reimplements a client and never touches key material. Providers
  # read their key from the environment lazily at first call; everything
  # here handles env var *names* only, so no key can appear in logs,
  # events, errors, or doctor output.
  #
  # Resolution order (explicit settings first, environment fallback):
  #   1. `LLMProviderSettings.provider` — an explicit setting always wins,
  #      including on conflict with the environment.
  #   2. Environment fallback: `ANTHROPIC_API_KEY` if present, else
  #      `OPENAI_API_KEY`. When both are present with no explicit setting,
  #      Anthropic wins (documented tie-break; set `provider` explicitly
  #      to override).
  #   3. Neither → no provider: the deterministic extraction floor is the
  #      supported zero-key mode, not an error.

  # The provider kind values (upstream `ProviderKind` literal). The
  # provider is carried as its string name, matching how settings/JSON
  # and Chronicle::ProviderConfig#type represent it.
  PROVIDER_KINDS = {"anthropic", "openai"}

  # Which env var carries each provider's key. Names only — the values
  # are read lazily by the runtime providers, never by this module.
  PROVIDER_KEY_ENVS = {
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai"    => "OPENAI_API_KEY",
  }

  # Which model each provider uses when none is configured explicitly.
  # Mirrors the runtime providers' `default_model`
  # (activegraph.llm.AnthropicProvider / OpenAIProvider), so extraction
  # has a deterministic model without per-behavior configuration.
  PROVIDER_DEFAULT_MODELS = {
    "anthropic" => "claude-sonnet-4-5",
    "openai"    => "gpt-4o-mini",
  }

  # Env-fallback probe order; also the tie-break when both keys exist.
  ENV_FALLBACK_ORDER = ["anthropic", "openai"]

  # The explicit-setting half of the resolution order. Everything is
  # optional: the empty settings object means "environment fallback
  # decides".
  struct LLMProviderSettings
    getter provider : String?
    getter model : String?
    getter api_key_env : String?

    def initialize(
      @provider : String? = nil,
      @model : String? = nil,
      @api_key_env : String? = nil,
    )
    end
  end

  # The resolution verdict: which provider, and from where. `api_key_env`
  # is the env var name the provider will read — safe to log and to print
  # from doctor. `provider` is nil in the zero-key mode (deterministic
  # floor only).
  struct ResolvedLLMProvider
    getter provider : String?
    getter source : String
    getter api_key_env : String?
    getter model : String?

    def initialize(
      @provider : String?,
      @source : String,
      @api_key_env : String?,
      @model : String?,
    )
    end

    def configured? : Bool
      !@provider.nil?
    end
  end

  # Apply the resolution order. Pure over (settings, env) — no I/O.
  # `env` defaults to the process environment when omitted.
  def self.resolve_llm_provider(
    settings : LLMProviderSettings? = nil,
    env : Hash(String, String)? = nil,
  ) : ResolvedLLMProvider
    s = settings || LLMProviderSettings.new

    if provider = s.provider
      return ResolvedLLMProvider.new(
        provider: provider,
        source: "setting",
        api_key_env: s.api_key_env || PROVIDER_KEY_ENVS[provider],
        model: s.model,
      )
    end

    ENV_FALLBACK_ORDER.each do |kind|
      key_env = PROVIDER_KEY_ENVS[kind]
      if key_env_present?(key_env, env)
        return ResolvedLLMProvider.new(
          provider: kind,
          source: "env",
          api_key_env: key_env,
          model: s.model,
        )
      end
    end

    ResolvedLLMProvider.new(
      provider: nil,
      source: "none",
      api_key_env: nil,
      model: nil,
    )
  end

  # Build the provider seam for a resolved configuration: a
  # Chronicle::ProviderConfig that the runtime's provider factories
  # consume. Returns nil in zero-key mode. Construction is lazy on the
  # provider side — the key env var is read at first call — so no key
  # value passes through here.
  def self.build_llm_provider(resolved : ResolvedLLMProvider) : Chronicle::ProviderConfig?
    provider = resolved.provider
    return nil if provider.nil?

    Chronicle::ProviderConfig.new(
      type: provider,
      api_key_env: resolved.api_key_env,
    )
  end

  # The model extraction should use: the explicit override, or the
  # provider's deterministic default model, or nil in the zero-key mode
  # (deterministic floor only).
  def self.default_model_for(resolved : ResolvedLLMProvider) : String?
    provider = resolved.provider
    return nil if provider.nil?

    resolved.model || PROVIDER_DEFAULT_MODELS[provider]
  end

  # ------------------------------------------------------- process registry
  #
  # The configured provider for this process (set once at startup, cleared
  # between test fixtures).

  class_property configured : ResolvedLLMProvider? = nil
  class_property provider_instance : Chronicle::ProviderConfig? = nil

  # Resolve and store this process's LLM provider configuration.
  def self.configure_llm_provider(
    settings : LLMProviderSettings? = nil,
    env : Hash(String, String)? = nil,
  ) : ResolvedLLMProvider
    resolved = resolve_llm_provider(settings, env)
    self.configured = resolved
    self.provider_instance = build_llm_provider(resolved)
    resolved
  end

  # The stored resolution; resolves from the environment on first use so
  # zero-configuration hosts still get the env fallback.
  def self.configured_llm_provider : ResolvedLLMProvider
    if (current = configured).nil?
      resolved = resolve_llm_provider
      self.configured = resolved
      self.provider_instance = build_llm_provider(resolved)
      resolved
    else
      current
    end
  end

  # The constructed provider seam, or nil (zero-key).
  # Upstream name is `get_llm_provider`; the Crystal accessor form drops
  # the `get_` prefix.
  def self.llm_provider : Chronicle::ProviderConfig?
    configured_llm_provider
    provider_instance
  end

  # Install an already-built provider (tests: recorded providers).
  def self.set_llm_provider(provider : Chronicle::ProviderConfig?, resolved : ResolvedLLMProvider) : Nil
    self.configured = resolved
    self.provider_instance = provider
  end

  # Reset the registry — call between test fixtures.
  def self.clear_llm_provider : Nil
    self.configured = nil
    self.provider_instance = nil
  end

  # Whether the env var for `name` holds a non-empty value, in either the
  # explicit env mapping or the process environment.
  private def self.key_env_present?(name : String, env : Hash(String, String)?) : Bool
    value = env ? env[name]? : ENV[name]?
    !value.nil? && !value.empty?
  end
end
