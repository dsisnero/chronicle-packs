require "spec"
require "json"
require "../spec_helper"

# Per-pack closed string-literal sets converted to enums (native
# to_json/from_json underscore-name round-trip).

describe "per-pack closed-set enums" do
  it "round-trips connector_control family, state, health, mode, and status sets" do
    cc = Chronicle::Packs::ConnectorControl
    Chronicle::Packs::ConnectorControl::ConnectorFamily::Conversation.to_json.should eq(%("conversation"))
    Chronicle::Packs::ConnectorControl::ConnectorFamily::Telemetry.to_json.should eq(%("telemetry"))
    Chronicle::Packs::ConnectorControl::NativeViewState::Partial.to_json.should eq(%("partial"))
    Chronicle::Packs::ConnectorControl::MaintenanceMode::ForegroundPoll.to_json.should eq(%("foreground_poll"))
    Chronicle::Packs::ConnectorControl::ConnectorRunState::Succeeded.to_json.should eq(%("succeeded"))
    Chronicle::Packs::ConnectorControl::ConnectorRunHealth::Current.to_json.should eq(%("current"))
    Chronicle::Packs::ConnectorControl::DeltaStatus::Collecting.to_json.should eq(%("collecting"))
    Chronicle::Packs::ConnectorControl::BindingStatus::Revoked.to_json.should eq(%("revoked"))
    Chronicle::Packs::ConnectorControl::MaintenanceRequestStatus::Rejected.to_json.should eq(%("rejected"))
  end

  it "round-trips tool_gateway risk class, call status, provider kind, and policy status" do
    tg = Chronicle::Packs::ToolGateway
    Chronicle::Packs::ToolGateway::RiskClass::Critical.to_json.should eq(%("critical"))
    Chronicle::Packs::ToolGateway::RiskClass.parse?("medium").should eq(Chronicle::Packs::ToolGateway::RiskClass::Medium)
    Chronicle::Packs::ToolGateway::CallStatus::PolicyChecking.to_json.should eq(%("policy_checking"))
    Chronicle::Packs::ToolGateway::CallStatus::Done.to_json.should eq(%("done"))
    Chronicle::Packs::ToolGateway::ProviderKind::Webhook.to_json.should eq(%("webhook"))
    Chronicle::Packs::ToolGateway::ToolPolicyStatus::Promoted.to_json.should eq(%("promoted"))
  end

  it "round-trips the shared ReliabilityVerdict" do
    Chronicle::Packs::ReliabilityVerdict::Harmful.to_json.should eq(%("harmful"))
    Chronicle::Packs::ReliabilityVerdict.parse?("supported").should eq(Chronicle::Packs::ReliabilityVerdict::Supported)
  end

  it "types connector_control surface and run observation fields as enums" do
    cc = Chronicle::Packs::ConnectorControl
    binding = Chronicle::Packs::ConnectorControl::ConnectorSurfaceBinding.from_json(JSON.build do |json|
      json.object do
        json.field "binding_identity", "b1"
        json.field "source_surface_id", "s1"
        json.field "service", "gmail"
        json.field "account_ref", "a1"
        json.field "family", "schedule"
        json.field "active_route", "native"
        json.field "domain_run_type", "connector_run"
        json.field "maintenance_mode", "foreground_poll"
        json.field "status", "stale"
      end
    end)
    binding.family.should eq(Chronicle::Packs::ConnectorControl::ConnectorFamily::Schedule)
    binding.maintenance_mode.should eq(Chronicle::Packs::ConnectorControl::MaintenanceMode::ForegroundPoll)
    binding.status.should eq(Chronicle::Packs::ConnectorControl::BindingStatus::Stale)

    run = Chronicle::Packs::ConnectorControl::ConnectorRunObservation.from_json(JSON.build do |json|
      json.object do
        json.field "observation_identity", "o1"
        json.field "domain_run_id", "run_1"
        json.field "source_surface_id", "s1"
        json.field "service", "gmail"
        json.field "account_ref", "a1"
        json.field "family", "conversation"
        json.field "route", "native"
        json.field "state", "succeeded"
        json.field "health", "current"
        json.field "phase", "done"
        json.field "mode", "manual"
      end
    end)
    run.family.should eq(Chronicle::Packs::ConnectorControl::ConnectorFamily::Conversation)
    run.state.should eq(Chronicle::Packs::ConnectorControl::ConnectorRunState::Succeeded)
    run.health.should eq(Chronicle::Packs::ConnectorControl::ConnectorRunHealth::Current)
  end
end
