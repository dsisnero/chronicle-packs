require "spec"
require "json"
require "../spec_helper"

# Remaining per-pack closed string-literal sets as enums (native
# to_json/from_json underscore-name round-trip).

describe "remaining per-pack closed-set enums" do
  it "round-trips eval_outcome verdict through the shared ReliabilityVerdict" do
    Chronicle::Packs::ReliabilityVerdict::Supported.to_json.should eq(%("supported"))
    Chronicle::Packs::ReliabilityVerdict::Harmful.to_json.should eq(%("harmful"))
    artifact = Chronicle::Packs::EvalOutcome::ArtifactReliability.from_json(%({"artifact_id":"a1","artifact_type":"memory_item","verdict":"harmful","latest_outcome_type":"outcome.hurt","latest_outcome_event_id":"e1"}))
    artifact.verdict.should eq(Chronicle::Packs::ReliabilityVerdict::Harmful)
  end

  it "round-trips attention signal type, source, priority band, and verdict" do
    Chronicle::Packs::Attention::AttentionSignalType::ActiveDwell.to_json.should eq(%("active_dwell"))
    Chronicle::Packs::Attention::AttentionSignalType::Revisited.to_json.should eq(%("revisited"))
    Chronicle::Packs::Attention::AttentionSource::Importer.to_json.should eq(%("importer"))
    Chronicle::Packs::Attention::PriorityBand::Unranked.to_json.should eq(%("unranked"))
    Chronicle::Packs::Attention::AttentionVerdict::Supported.to_json.should eq(%("supported"))
  end

  it "round-trips skills status, execution kind, and skill kind" do
    Chronicle::Packs::Skills::SkillStatus::Demoted.to_json.should eq(%("demoted"))
    Chronicle::Packs::Skills::ExecutionKind::Trial.to_json.should eq(%("trial"))
    Chronicle::Packs::Skills::SkillKind::RepeatedAcceptedUse.to_json.should eq(%("repeated_accepted_use"))
  end

  it "round-trips entity types, merge candidate status, and mention decision" do
    Chronicle::Packs::Entity::EntityType::Organization.to_json.should eq(%("organization"))
    Chronicle::Packs::Entity::MergeCandidateStatus::Deferred.to_json.should eq(%("deferred"))
    Chronicle::Packs::Entity::MentionDecision::Rejected.to_json.should eq(%("rejected"))
  end
end
