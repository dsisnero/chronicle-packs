require "spec"
require "json"
require "../spec_helper"

# Shared closed string-literal sets modeled as enums (AGENTS.md: closed sets
# are enums; non-flags enums serialize as the underscored member name).

describe "shared closed-set enums" do
  it "round-trip SourceCategory through underscore-name JSON" do
    Chronicle::Packs::SourceCategory::AiActivity.to_json.should eq(%("ai_activity"))
    Chronicle::Packs::SourceCategory::CodeWork.to_json.should eq(%("code_work"))
    Chronicle::Packs::SourceCategory::LocalKnowledge.to_json.should eq(%("local_knowledge"))
    Chronicle::Packs::SourceCategory::ToolAutomation.to_json.should eq(%("tool_automation"))
    Chronicle::Packs::SourceCategory::OutcomeEvaluation.to_json.should eq(%("outcome_evaluation"))
    Chronicle::Packs::SourceCategory::Communication.to_json.should eq(%("communication"))
    Chronicle::Packs::SourceCategory.parse?("ai_activity").should eq(Chronicle::Packs::SourceCategory::AiActivity)
    Chronicle::Packs::SourceCategory.parse?("unknown").should be_nil
  end

  it "round-trips ConnectionPath, ReplayMode, and SurfaceStatus" do
    Chronicle::Packs::ConnectionPath::Composio.to_json.should eq(%("composio"))
    Chronicle::Packs::ConnectionPath::Mcp.to_json.should eq(%("mcp"))
    Chronicle::Packs::ReplayMode::ReferenceOnly.to_json.should eq(%("reference_only"))
    Chronicle::Packs::SurfaceStatus::Settling.to_json.should eq(%("settling"))
    Chronicle::Packs::SurfaceStatus.parse?("revoked").should eq(Chronicle::Packs::SurfaceStatus::Revoked)
  end

  it "types usage surface fields as the shared enums" do
    surface = Chronicle::Packs::Usage::ConnectionSurface.from_json(JSON.build do |json|
      json.object do
        json.field "surface_id", "chat/sess_1"
        json.field "category", "ai_activity"
        json.field "path", "mcp"
        json.field "status", "settling"
        json.field "acquisition_mode", "live"
        json.field "privacy_scope", "account"
      end
    end)
    surface.category.should eq(Chronicle::Packs::SourceCategory::AiActivity)
    surface.path.should eq(Chronicle::Packs::ConnectionPath::Mcp)
    surface.status.should eq(Chronicle::Packs::SurfaceStatus::Settling)
  end

  it "types activity_normalizer evidence fields as the shared enums" do
    item = Chronicle::Packs::ActivityNormalizer::AcquiredItem.from_json(JSON.build do |json|
      json.object do
        json.field "source_surface_id", "chat/sess_1"
        json.field "dedup_key", "d1"
        json.field "source_ref", "r1"
        json.field "replay_mode", "reference_only"
        json.field "replay_payload_ref", ""
        json.field "replay_payload_hash", "0" * 64
        json.field "media_type", "text/plain"
        json.field "importer_id", "i"
        json.field "importer_version", "1"
      end
    end)
    item.replay_mode.should eq(Chronicle::Packs::ReplayMode::ReferenceOnly)
  end
end
