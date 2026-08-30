require "spec"
require "digest"
require "file_utils"
require "../spec_helper"

# Evolution Pack review — the adoption decision surface (design §3 stage 4).
# Translated from upstream packs/evolution/review.py (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0).
#
# Everything comes from graph state alone: `build_review` is a pure read
# over the objects the pipeline already wrote, and `render_review_html` is a
# deterministic renderer over that model. No candidate code is imported,
# executed, or written to disk here; agent-authored text is escaped
# everywhere it appears. The unified diff rides the `similar` shard
# (dsisnero/similar.cr), configured to match Python difflib's `lineterm=""`
# line output.

module EvolutionReviewSpecSupport
  extend self

  def review_runtime(&)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::ToolGateway.pack).should be_true
    rt.load_pack(Chronicle::Packs::IdentityAuth.pack).should be_true
    settings = Chronicle::Packs::Evolution::EvolutionSettings.new(enabled: true)
    rt.load_pack(Chronicle::Packs::Evolution.pack, JSON.parse(settings.to_json).as_h).should be_true
    yield store, graph, rt
  end

  # A gate-compliant candidate (like upstream's author_pack with the
  # content hash computed over the exact files).
  def candidate_files
    source = <<-CRYSTAL
      module GreeterPack
        @[Chronicle::Packs::Annotations::ObjectType(name: "greeting_log", description: "A greeting record.")]
        struct GreetingLog
        end

        @[Chronicle::Packs::Annotations::Behavior(name: "greeter", on: ["object.created"])]
        def self.greeter
        end
      end
      CRYSTAL
    files = {
      "manifest.toml" => %([pack]\nname = "greeter_pack"\nversion = "0.1.0"\n\n[pack.provenance]\nauthored_by = "agent"\n\n[surface]\nbehaviors = ["greeter"]\nobject_types = ["greeting_log"]\ntools = []\nsettings_schema = "GreeterSettings"\n),
      "pack.cr"       => source,
    }
    # content_hash over the files (sans manifest) via chronicle's hash
    root = Chronicle::Packs::Evolution::Materialize.write_files(files, pack_name: "greeter_pack_review")
    hash = Chronicle::Packs.compute_content_hash(root.to_s)
    FileUtils.rm_rf(root)
    files["manifest.toml"] = files["manifest.toml"].sub("settings_schema = \"GreeterSettings\"", "settings_schema = \"GreeterSettings\"\n\n[pack.integrity]\ncontent_hash = \"#{hash}\"")
    files
  end

  def submit_candidate(graph, rt, gap_id : String = "")
    proposal = Chronicle::Packs::Evolution.submit_proposal_fn(
      graph, pack_name: "greeter_pack", files: candidate_files, gap_id: gap_id)
    rt.run_until_idle
    proposal
  end

  def add_gate_result(graph, proposal_id : String, gate : String, verdict : String, details : String = "")
    graph.add_object("gate_result", {
      "proposal_id" => JSON::Any.new(proposal_id), "gate" => JSON::Any.new(gate),
      "verdict" => JSON::Any.new(verdict), "details" => JSON::Any.new(details), "at" => JSON::Any.new("2026-07-08T00:00:00+00:00"),
    }.to_json, actor: "spec")
  end
end

include EvolutionReviewSpecSupport

describe Chronicle::Packs::Evolution do
  describe "review" do
    it "_esc escapes HTML in quoted mode" do
      Chronicle::Packs::Evolution::Review._esc("a < b & \"c\" 'd'").should eq("a &lt; b &amp; &quot;c&quot; &#39;d&#39;")
    end

    it "_kv_rows renders a table of escaped rows" do
      rows = Chronicle::Packs::Evolution::Review._kv_rows([{"status", "a<b"}])
      rows.should eq("<tr><th>status</th><td>a&lt;b</td></tr>")
    end

    it "_gap_view returns the gap model or nil" do
      review_runtime do |_store, graph, _rt|
        gap = graph.add_object("capability_gap", {
          "kind" => JSON::Any.new("tool_failure"), "description" => JSON::Any.new("x failed"),
          "status" => JSON::Any.new("open"),
          "injection_flags" => JSON::Any.new([JSON::Any.new("flag")]),
          "evidence_refs" => JSON::Any.new([JSON::Any.new("evt_1")]),
        }.to_json)
        view = Chronicle::Packs::Evolution::Review._gap_view(graph, gap.id)
        view.not_nil!["id"].should eq(gap.id)
        view.not_nil!["kind"].should eq("tool_failure")
        view.not_nil!["injection_flags"].should eq(["flag"])
        Chronicle::Packs::Evolution::Review._gap_view(graph, "capability_gap#999").should be_nil
        Chronicle::Packs::Evolution::Review._gap_view(graph, "").should be_nil
      end
    end

    it "_drafting_view renders the drafting record or a missing marker" do
      review_runtime do |_store, graph, _rt|
        rec = graph.add_object("drafting_context", {
          "model" => JSON::Any.new("scripted"), "charter_hash" => JSON::Any.new("sha256:abc"),
          "gap_id" => JSON::Any.new("g1"), "at" => JSON::Any.new("t"),
          "structured_fields" => JSON::Any.new([] of JSON::Any),
          "surface_sources" => JSON::Any.new([] of JSON::Any),
          "owner_input_ids" => JSON::Any.new([] of JSON::Any),
          "injection_flags" => JSON::Any.new([] of JSON::Any),
        }.to_json)
        view = Chronicle::Packs::Evolution::Review._drafting_view(graph, rec.id)
        view.not_nil!["model"].should eq("scripted")
        view.not_nil!["missing"].should be_false
        missing = Chronicle::Packs::Evolution::Review._drafting_view(graph, "drafting_context#999")
        missing.not_nil!["missing"].should be_true
        Chronicle::Packs::Evolution::Review._drafting_view(graph, "").should be_nil
      end
    end

    it "_unified_diff produces per-file added/unchanged/modified/removed entries with lines" do
      files = {
        "a.py" => "line1\nline2\nline3\n",
        "b.py" => "keep\n",
      }
      diff = Chronicle::Packs::Evolution::Review._unified_diff({} of String => String, files)
      by_path = diff.to_h { |e| {e["path"].as_s, e} }
      a = by_path["a.py"]
      a["status"].should eq("added")
      a["size_bytes"].should eq(18)
      a["lines"].as_a.size.should be > 0
      a["lines"].as_a.first.as_s.should eq("--- adopted/a.py")
      a["lines"].as_a.last.as_s.should eq("+line3")

      unchanged = Chronicle::Packs::Evolution::Review._unified_diff({"x" => "same\n"}, {"x" => "same\n"})
      unchanged.first["status"].should eq("unchanged")
      unchanged.first["lines"].as_a.should be_empty

      modified = Chronicle::Packs::Evolution::Review._unified_diff({"x" => "old\n"}, {"x" => "new\n"})
      modified.first["status"].should eq("modified")

      removed = Chronicle::Packs::Evolution::Review._unified_diff({"x" => "gone\n"}, {} of String => String)
      removed.first["status"].should eq("removed")
    end

    it "_manifest_view parses manifest.toml (never trusted, only displayed)" do
      files = {
        "manifest.toml" => %([pack]\nname = "greeter_pack"\nversion = "0.1.0"\ndescription = "d"\n\n[pack.provenance]\nauthored_by = "agent"\n\n[surface]\nbehaviors = ["greeter"]\nobject_types = ["greeting_log"]\nrelation_types = []\ntools = []\n\n[[surface.capabilities]]\nprovider = "greeter"\ncapability = "say_hi"\nrisk_class = "low"\n),
      }
      view = Chronicle::Packs::Evolution::Review._manifest_view(files)
      view["name"].should eq("greeter_pack")
      view["version"].should eq("0.1.0")
      view["authored_by"].should eq("agent")
      view["behaviors"].should eq(["greeter"])
      view["object_types"].should eq(["greeting_log"])
      caps = view["capabilities"].as_a
      caps.size.should eq(1)
      caps[0].as_h["key"].as_s.should eq("greeter.say_hi")
      caps[0].as_h["risk_class"].as_s.should eq("low")

      bad = Chronicle::Packs::Evolution::Review._manifest_view({"manifest.toml" => "not toml {{{"})
      bad["error"].as_s.should contain("does not parse")
    end

    it "_pending_call finds the held evolution.adopt_proposal call for a proposal" do
      review_runtime do |_store, graph, rt|
        Chronicle::Packs::ToolGateway.register_local_capability(
          "evolution", "adopt_proposal",
          ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} },
          description: "adopt", risk_class: "critical", action_class: "R4",
        )
        proposal = graph.add_object("mod_proposal", {"pack_name" => JSON::Any.new("x"), "status" => JSON::Any.new("trialed")}.to_json)
        req = Chronicle::Packs::Evolution.request_adoption_fn(graph, proposal_id: proposal.id, proposed_by: "fixture")
        rt.run_until_idle
        view = Chronicle::Packs::Evolution::Review._pending_call(graph, proposal.id)
        view.not_nil!["call_id"].as_s.should eq(req["call_id"].as_s)
        Chronicle::Packs::Evolution::Review._pending_call(graph, "mod_proposal#999").should be_nil
      end
    end

    it "build_review assembles the full model from graph state and raises on a missing proposal" do
      review_runtime do |_store, graph, rt|
        proposal = submit_candidate(graph, rt)
        add_gate_result(graph, proposal.id, "static:injection", "pass")
        add_gate_result(graph, proposal.id, "static:size", "pass")

        review = Chronicle::Packs::Evolution::Review.build_review(graph, proposal.id)
        review["proposal"]["id"].should eq(proposal.id)
        review["proposal"]["pack_name"].should eq("greeter_pack")
        review["proposal"]["authored_by"].should eq("agent")
        review["gap"].raw.should be_nil
        gates = review["gates"].as_a
        gates.map { |gate| gate.as_h["gate"].as_s }.should eq([
          "static:reserved_paths", "static:file_set", "static:manifest",
          "static:hash", "static:manifest_surface", "static:requires",
          "static:banned_constructs", "static:reserved", "static:size",
          "static:injection", "static:injection", "static:size",
        ])
        review["diff"].as_a.size.should eq(candidate_files.size)
        review["diff"].as_a.all? { |e| e["status"].as_s == "added" }.should be_true
        review["manifest"]["behaviors"].should eq(["greeter"])
        review["trial"].raw.should be_nil
        review["promotions"].as_a.should be_empty
        review["injection_flags"].as_a.should be_empty
        review["proposal"].as_h["status"].as_s.should eq("gated")
        review["decidable"].should be_true

        expect_raises(KeyError, /no mod_proposal/) do
          Chronicle::Packs::Evolution::Review.build_review(graph, "mod_proposal#999")
        end
      end
    end

    it "build_review aggregates injection flags across proposal/gap/drafting" do
      review_runtime do |_store, graph, rt|
        gap = graph.add_object("capability_gap", {
          "kind" => JSON::Any.new("reflection"), "description" => JSON::Any.new("d"),
          "status" => JSON::Any.new("open"),
          "injection_flags" => JSON::Any.new([JSON::Any.new("prompt_injection")]),
        }.to_json)
        proposal = submit_candidate(graph, rt, gap_id: gap.id)
        review = Chronicle::Packs::Evolution::Review.build_review(graph, proposal.id)
        review["injection_flags"].should eq(["prompt_injection"])
        review["gap"].as_h["id"].as_s.should eq(gap.id)
      end
    end

    it "render_review_html renders the one-page decision surface deterministically" do
      review_runtime do |_store, graph, rt|
        proposal = submit_candidate(graph, rt)
        add_gate_result(graph, proposal.id, "static:injection", "pass")
        review = Chronicle::Packs::Evolution::Review.build_review(graph, proposal.id)
        page = Chronicle::Packs::Evolution::Review.render_review_html(review)

        page.should contain("<!DOCTYPE html>")
        page.should contain("Adoption review: <code>greeter_pack</code> v0.1.0")
        page.should contain("AUTHORED BY: AGENT")
        page.should contain("&mdash; this code was written by the assistant.")
        page.should contain("No injection flags on this proposal or its gap lineage.")
        page.should contain("bundle hash (the approval pin)")
        page.should contain("static:injection")
        page.should contain("No trial recorded. Do not approve an untrialed proposal.")
        page.should contain("manifest.toml")
        page.should contain("Full source diff")
        # The agent-authored source diff is on the page (escaped, not raw).
        page.should contain("<span class='diff-add'>+  @[Chronicle::Packs::Annotations::Behavior(")
        page.should contain("No held approval call yet")
        # Deterministic.
        Chronicle::Packs::Evolution::Review.render_review_html(review).should eq(page)
      end
    end

    it "render_review_html renders taint loudly with no decision and a held call" do
      review_runtime do |_store, graph, rt|
        gap = graph.add_object("capability_gap", {
          "kind" => JSON::Any.new("reflection"), "description" => JSON::Any.new("d"),
          "status" => JSON::Any.new("open"),
          "injection_flags" => JSON::Any.new([JSON::Any.new("instruction_override")]),
        }.to_json)
        proposal = submit_candidate(graph, rt, gap_id: gap.id)
        Chronicle::Packs::ToolGateway.register_local_capability(
          "evolution", "adopt_proposal",
          ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} },
          description: "adopt", risk_class: "critical", action_class: "R4",
        )
        req = Chronicle::Packs::Evolution.request_adoption_fn(graph, proposal_id: proposal.id, proposed_by: "fixture")
        rt.run_until_idle

        review = Chronicle::Packs::Evolution::Review.build_review(graph, proposal.id)
        review["injection_flags"].should eq(["instruction_override"])
        review["pending_call"].not_nil!.as_h["call_id"].as_s.should eq(req["call_id"].as_s)

        page = Chronicle::Packs::Evolution::Review.render_review_html(review)
        page.should contain("INJECTION FLAGS ON THIS LINEAGE")
        page.should contain("instruction_override")
        page.should contain("Approve adoption")
        page.should contain(req["call_id"].as_s)
      end
    end

    it "render_approvals_index_html lists held calls and links evolution adoptions to their review" do
      review_runtime do |_store, graph, rt|
        proposal = submit_candidate(graph, rt)
        Chronicle::Packs::ToolGateway.register_local_capability(
          "evolution", "adopt_proposal",
          ->(input : Hash(String, JSON::Any)) { {"ok" => JSON::Any.new(true)} },
          description: "adopt", risk_class: "critical", action_class: "R4",
        )
        Chronicle::Packs::Evolution.request_adoption_fn(graph, proposal_id: proposal.id, proposed_by: "fixture")
        rt.run_until_idle

        index = Chronicle::Packs::Evolution::Review.render_approvals_index_html(graph)
        index.should contain("Held approvals")
        index.should contain("evolution.adopt_proposal")
        index.should contain("proposal_id=#{proposal.id}")
      end
    end
  end
end
