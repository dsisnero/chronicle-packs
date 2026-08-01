require "spec"
require "../spec_helper"

# Packs-level LLM provider configuration. Ported from upstream
# packs/llm_provider.py + tests/test_llm_provider.py (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). The doctor-side checks
# (check_llm_provider) are deferred to the doctor feature (Tier 7).
#
# Resolution order (explicit settings first, environment fallback):
#   1. LLMProviderSettings.provider — explicit always wins, including on
#      conflict with the environment.
#   2. Environment fallback: ANTHROPIC_API_KEY if present, else
#      OPENAI_API_KEY; when both are present Anthropic wins.
#   3. Neither -> no provider: the deterministic floor, not an error.

FAKE_ANTHROPIC_KEY = "sk-ant-FAKE-key-material-9f8e7d6c5b4a"
FAKE_OPENAI_KEY    = "sk-proj-FAKE-key-material-1a2b3c4d5e6f"

private def with_clean_registry(&)
  Chronicle::Packs::LLMProvider.clear_llm_provider
  begin
    yield
  ensure
    Chronicle::Packs::LLMProvider.clear_llm_provider
  end
end

# Set ENV vars for the block, restoring prior values afterwards.
private def with_env(vars : Hash(String, String), &)
  previous = {} of String => String?
  vars.each_key do |name|
    previous[name] = ENV[name]?
    ENV[name] = vars[name]
  end
  begin
    yield
  ensure
    previous.each do |name, value|
      if value
        ENV[name] = value
      else
        ENV.delete(name)
      end
    end
  end
end

describe Chronicle::Packs::LLMProvider do
  describe ".resolve_llm_provider" do
    it "resolves to none with no setting and no env" do
      resolved = Chronicle::Packs::LLMProvider.resolve_llm_provider(env: {} of String => String)
      resolved.provider.should be_nil
      resolved.source.should eq("none")
      resolved.configured?.should be_false
      Chronicle::Packs::LLMProvider.build_llm_provider(resolved).should be_nil
    end

    it "falls back to whichever env key is present" do
      anthropic = Chronicle::Packs::LLMProvider.resolve_llm_provider(
        env: {"ANTHROPIC_API_KEY" => FAKE_ANTHROPIC_KEY}
      )
      anthropic.provider.should eq("anthropic")
      anthropic.source.should eq("env")
      anthropic.api_key_env.should eq("ANTHROPIC_API_KEY")

      openai = Chronicle::Packs::LLMProvider.resolve_llm_provider(
        env: {"OPENAI_API_KEY" => FAKE_OPENAI_KEY}
      )
      openai.provider.should eq("openai")
      openai.source.should eq("env")
      openai.api_key_env.should eq("OPENAI_API_KEY")
    end

    it "breaks toward anthropic when both env keys are present" do
      resolved = Chronicle::Packs::LLMProvider.resolve_llm_provider(
        env: {"ANTHROPIC_API_KEY" => FAKE_ANTHROPIC_KEY, "OPENAI_API_KEY" => FAKE_OPENAI_KEY}
      )
      resolved.provider.should eq("anthropic")
      resolved.source.should eq("env")
    end

    it "lets an explicit setting win on conflict with the environment" do
      resolved = Chronicle::Packs::LLMProvider.resolve_llm_provider(
        Chronicle::Packs::LLMProvider::LLMProviderSettings.new(provider: "openai"),
        env: {"ANTHROPIC_API_KEY" => FAKE_ANTHROPIC_KEY, "OPENAI_API_KEY" => FAKE_OPENAI_KEY},
      )
      resolved.provider.should eq("openai")
      resolved.source.should eq("setting")
      resolved.api_key_env.should eq("OPENAI_API_KEY")
    end

    it "lets a setting override the model and the key env var name" do
      resolved = Chronicle::Packs::LLMProvider.resolve_llm_provider(
        Chronicle::Packs::LLMProvider::LLMProviderSettings.new(
          provider: "anthropic",
          model: "claude-haiku-4-5",
          api_key_env: "MY_ANTHROPIC_KEY",
        ),
        env: {} of String => String,
      )
      resolved.model.should eq("claude-haiku-4-5")
      resolved.api_key_env.should eq("MY_ANTHROPIC_KEY")
    end
  end

  describe ".build_llm_provider" do
    it "returns nil in zero-key mode" do
      resolved = Chronicle::Packs::LLMProvider.resolve_llm_provider(env: {} of String => String)
      Chronicle::Packs::LLMProvider.build_llm_provider(resolved).should be_nil
    end

    it "builds a provider seam config, not a key-bearing client" do
      anthropic = Chronicle::Packs::LLMProvider.build_llm_provider(
        Chronicle::Packs::LLMProvider.resolve_llm_provider(env: {"ANTHROPIC_API_KEY" => FAKE_ANTHROPIC_KEY})
      )
      anthropic.should_not be_nil
      anthropic.not_nil!.type.should eq("anthropic")
      anthropic.not_nil!.api_key_env.should eq("ANTHROPIC_API_KEY")
      anthropic.not_nil!.api_key.should be_nil

      openai = Chronicle::Packs::LLMProvider.build_llm_provider(
        Chronicle::Packs::LLMProvider.resolve_llm_provider(env: {"OPENAI_API_KEY" => FAKE_OPENAI_KEY})
      )
      openai.not_nil!.type.should eq("openai")
      openai.not_nil!.api_key_env.should eq("OPENAI_API_KEY")
    end
  end

  describe "process registry" do
    it "configure then get, clear resets to none" do
      with_clean_registry do
        resolved = Chronicle::Packs::LLMProvider.configure_llm_provider(
          Chronicle::Packs::LLMProvider::LLMProviderSettings.new(provider: "anthropic"),
          env: {} of String => String,
        )
        resolved.source.should eq("setting")
        Chronicle::Packs::LLMProvider.llm_provider.should_not be_nil

        Chronicle::Packs::LLMProvider.clear_llm_provider
        Chronicle::Packs::LLMProvider.configure_llm_provider(env: {} of String => String)
        Chronicle::Packs::LLMProvider.llm_provider.should be_nil
      end
    end

    it "configured_llm_provider resolves from the environment on first use" do
      with_clean_registry do
        with_env({"ANTHROPIC_API_KEY" => FAKE_ANTHROPIC_KEY}) do
          resolved = Chronicle::Packs::LLMProvider.configured_llm_provider
          resolved.provider.should eq("anthropic")
          resolved.source.should eq("env")
          Chronicle::Packs::LLMProvider.llm_provider.should_not be_nil
        end
      end
    end

    it "set_llm_provider installs an already-built provider" do
      with_clean_registry do
        config = Chronicle::ProviderConfig.new(type: "openai", api_key_env: "OPENAI_API_KEY")
        resolved = Chronicle::Packs::LLMProvider::ResolvedLLMProvider.new(
          provider: "openai", source: "setting", api_key_env: "OPENAI_API_KEY", model: nil
        )
        Chronicle::Packs::LLMProvider.set_llm_provider(config, resolved)
        Chronicle::Packs::LLMProvider.llm_provider.should eq(config)
        Chronicle::Packs::LLMProvider.configured_llm_provider.provider.should eq("openai")
      end
    end
  end

  describe "default_model_for" do
    it "returns the explicit override, or nil in zero-key mode" do
      Chronicle::Packs::LLMProvider.default_model_for(
        Chronicle::Packs::LLMProvider.resolve_llm_provider(env: {} of String => String)
      ).should be_nil

      override = Chronicle::Packs::LLMProvider.default_model_for(
        Chronicle::Packs::LLMProvider::ResolvedLLMProvider.new(
          provider: "anthropic", source: "setting", api_key_env: "ANTHROPIC_API_KEY", model: "claude-haiku-4-5"
        )
      )
      override.should eq("claude-haiku-4-5")
    end
  end

  it "never surfaces key material in the resolution verdict" do
    resolved = Chronicle::Packs::LLMProvider.resolve_llm_provider(
      env: {"ANTHROPIC_API_KEY" => FAKE_ANTHROPIC_KEY}
    )
    surfaces = [resolved.provider.to_s, resolved.source, resolved.api_key_env.to_s, resolved.inspect]
    surfaces.each do |surface|
      surface.should_not contain(FAKE_ANTHROPIC_KEY)
    end
  end
end
