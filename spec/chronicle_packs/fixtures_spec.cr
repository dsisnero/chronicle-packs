require "spec"
require "../spec_helper"

# Cross-pack integration fixtures (upstream packs/fixtures/*).
#
# Each fixture runs a full multi-pack scenario in-process (no subprocess, no
# LLM, no API key) and asserts the integration shape — the deterministic
# driver pattern established by the per-pack fixtures. Mirrors the upstream
# test_cross_pack_fixtures.py test names.
module FixtureSpecSupport
  extend self

  def hermetic
    Chronicle::Packs::Conftest.hermetic_environment
  end
end

include FixtureSpecSupport

describe Chronicle::Packs::Fixtures do
  describe "cross_pack_integration (Tool Gateway → Core → Memory Gateway)" do
    it "runs the full graph-driven capability → core → memory pipeline" do
      hermetic
      Chronicle::Packs::Fixtures.run_cross_pack_integration.should be_true
    end
  end

  describe "comm_chat_email_integration (Communication + Chat + Email + Identity + Core)" do
    it "runs the full communication stack" do
      hermetic
      result = Chronicle::Packs::Fixtures.run_full_comm_stack_integration
      result["sources"].as_i.should eq(1)
      result["comm_messages"].as_i.should eq(1)
      result["comm_threads"].as_i.should eq(1)
      result["email_threads"].as_i.should eq(1)
      result["owner_principals"].as_i.should be >= 1
      result["external_principals"].as_i.should be >= 1
      result["email_drafts"].as_i.should eq(1)
      result["approval_actions"].as_i.should be >= 1
      result["chat_sessions"].as_i.should eq(1)
      result["chat_turns"].as_i.should eq(1)
      result["chat_assistant_message_populated"].as_bool.should be_true
      result["email_thread_message_count"].as_i.should eq(2)
    end

    it "run_all returns true" do
      hermetic
      Chronicle::Packs::Fixtures.run_all_comm_chat_email.should be_true
    end
  end

  describe "identity_profile_entity_integration (Identity + Agent Profile + Entity)" do
    it "resolves the owner, extracts entities, and assembles a profile context" do
      hermetic
      Chronicle::Packs::Fixtures.run_identity_profile_entity_composition.should be_true
    end

    it "run_all returns true" do
      hermetic
      Chronicle::Packs::Fixtures.run_all_identity_profile_entity.should be_true
    end
  end

  describe "chat_memory_cross_session" do
    it "recalls a preference written in session 1 from a fresh session 2" do
      hermetic
      result = Chronicle::Packs::Fixtures.run_cross_session_memory
      result["stored_count"].as_i.should be >= 1
      result["contexts"].as_i.should be >= 1
      result["recalled_items"].as_i.should be >= 1
      result["summaries"].as_a.any? { |s| s.as_s.downcase.includes?("dark mode") }.should be_true
    end
  end

  describe "l2_habit_integration (closed deterministic L2 loop)" do
    it "runs the skill lifecycle, memory reliability, and usage loop" do
      hermetic
      result = Chronicle::Packs::Fixtures.run_l2_habit_fixture
      result["skill_used_events"].as_i.should eq(1)
      result["terminal_outcome"].as_s.should eq("outcome.helped")
      result["interaction_utc_dates"].as_a.map(&.as_s).should eq(["2026-07-09", "2026-07-10"])
      memory = result["memory"].as_h
      memory["demoted_multiplier"].as_f.should eq(0.1)
      memory["restored_multiplier"].as_f.should eq(1.0)
    end
  end

  describe "run_all" do
    it "runs every fixture and exits 0 when all pass" do
      hermetic
      Chronicle::Packs::Fixtures.main([] of String, io: IO::Memory.new).should eq(0)
    end
  end
end
