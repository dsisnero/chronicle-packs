require "spec"
require "../spec_helper"

# Identity/Auth pack (packs/identity_auth): principal resolution, role-based
# access, and permission checking. Ported from upstream
# packs/identity_auth/* (revision 6639a5385518ad49f74813373c85cf96eff9adc0).
# All behaviors are deterministic and run with no API key.

module IdentityAuthSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "identity_auth" / "manifest.toml"
  end

  def settings(json : String) : Chronicle::Packs::IdentityAuth::IdentitySettings
    Chronicle::Packs::IdentityAuth::IdentitySettings.from_json(json)
  end

  def with_identity_runtime(settings : Chronicle::Packs::IdentityAuth::IdentitySettings? = nil, &)
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    if settings
      rt.load_pack(Chronicle::Packs::IdentityAuth.pack, JSON.parse(settings.to_json).as_h).should be_true
    else
      rt.load_pack(Chronicle::Packs::IdentityAuth.pack).should be_true
    end
    Chronicle::Packs::IdentityAuth.clear_principal_registry
    yield store, graph, rt
  ensure
    Chronicle::Packs::IdentityAuth.clear_principal_registry
  end
end

include IdentityAuthSpecSupport

describe Chronicle::Packs::IdentityAuth do
  describe "manifest-declared surface" do
    it "matches the upstream identity_auth manifest" do
      pack = Chronicle::Packs::IdentityAuth.pack
      pack.name.should eq("identity_auth")
      pack.version.should eq("0.2.1")
      pack.object_types.map(&.name).should eq(
        ["principal", "auth_context", "role", "permission", "delegation"]
      )
      pack.relation_types.map(&.name).should eq(
        ["resolves_to", "authenticated_by", "granted_by", "granted_to", "linked_to_entity"]
      )
      pack.behaviors.map(&.name).should eq(
        ["principal_resolver", "comm_message_principal_resolver", "auth_context_builder",
         "principal_entity_linker", "permission_checker"]
      )
      pack.tools.map(&.name).should eq(["lookup_principal", "check_principal_permission", "register_principal"])
      pack.settings_schema.should eq("IdentitySettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::IdentityAuth.pack)
    end
  end

  describe "role-based capability hierarchy" do
    it "grants owner every action" do
      Chronicle::Packs::IdentityAuth.can_action?("owner", "anything").should be_true
    end

    it "grants admin management, read, write, execute, and comment" do
      %w[manage_settings manage_collaborators read write execute comment].each do |action|
        Chronicle::Packs::IdentityAuth.can_action?("admin", action).should be_true
      end
      Chronicle::Packs::IdentityAuth.can_action?("admin", "read_public").should be_false
    end

    it "grants collaborator read/write/comment but not execute" do
      %w[read write comment].each do |action|
        Chronicle::Packs::IdentityAuth.can_action?("collaborator", action).should be_true
      end
      Chronicle::Packs::IdentityAuth.can_action?("collaborator", "execute").should be_false
    end

    it "scopes external to read_public and customer to read_own" do
      Chronicle::Packs::IdentityAuth.can_action?("external", "read_public").should be_true
      Chronicle::Packs::IdentityAuth.can_action?("external", "read").should be_false
      Chronicle::Packs::IdentityAuth.can_action?("customer", "read_own").should be_true
      Chronicle::Packs::IdentityAuth.can_action?("customer", "read_public").should be_false
    end

    it "denies unknown and blocked principals everything" do
      Chronicle::Packs::IdentityAuth.can_action?("unknown", "read").should be_false
      Chronicle::Packs::IdentityAuth.can_action?("blocked", "read").should be_false
    end
  end

  describe "principal_resolver" do
    it "resolves an owner sender_ref to an owner principal" do
      with_identity_runtime(settings(%({"owner_identifiers":["alice@example.com"],"owner_auth_confidence":0.95}))) do |_store, graph, rt|
        graph.add_object("source", %({"kind":"chat_message","content":"Hi","sender_ref":"alice@example.com","channel":"chat","frame_id":"f1"}))
        rt.run_until_idle

        principals = graph.objects(type: "principal")
        principals.size.should eq(1)
        data = JSON.parse(principals.first.data)
        data["role"].as_s.should eq("owner")
        data["auth_confidence"].as_f.should eq(0.95)
        data["name"].as_s.should eq("alice@example.com")
        data["identifiers"].as_h["email"].as_s.should eq("alice@example.com")

        graph.relations(source: graph.objects(type: "source").first.id, type: "resolves_to")
          .map(&.to_id).should eq([principals.first.id])
      end
    end

    it "assigns the default external role to unknown senders" do
      with_identity_runtime(settings(%({"default_external_role":"external","default_auth_confidence":0.4}))) do |_store, graph, rt|
        graph.add_object("source", %({"kind":"email","content":"Hi","sender_ref":"vendor@unknown.org","channel":"email","frame_id":"f2"}))
        rt.run_until_idle

        principals = graph.objects(type: "principal")
        principals.size.should eq(1)
        data = JSON.parse(principals.first.data)
        data["role"].as_s.should eq("external")
        data["auth_confidence"].as_f.should eq(0.4)
        data["name"].as_s.should eq("Vendor")
      end
    end

    it "deduplicates by normalized sender_ref on revisit" do
      with_identity_runtime do |_store, graph, rt|
        graph.add_object("source", %({"kind":"chat_message","content":"one","sender_ref":"alice@example.com","channel":"chat"}))
        rt.run_until_idle
        graph.add_object("source", %({"kind":"chat_message","content":"two","sender_ref":"ALICE@example.com ","channel":"chat"}))
        rt.run_until_idle

        principals = graph.objects(type: "principal")
        principals.size.should eq(1)
        data = JSON.parse(principals.first.data)
        data["seen_count"].as_i.should eq(2)
      end
    end

    it "does not resolve sources without a sender_ref" do
      with_identity_runtime do |_store, graph, rt|
        graph.add_object("source", %({"kind":"file","content":"no sender"}))
        rt.run_until_idle
        graph.objects(type: "principal").should be_empty
      end
    end
  end

  describe "comm_message_principal_resolver" do
    it "resolves a comm_message sender to a principal sharing the registry" do
      with_identity_runtime(settings(%({"owner_identifiers":["alice@example.com"]}))) do |_store, graph, rt|
        graph.add_object("source", %({"kind":"chat_message","content":"hi","sender_ref":"alice@example.com","channel":"chat"}))
        rt.run_until_idle
        graph.add_object("comm_message", %({"text":"hello","sender_ref":"alice@example.com","channel":"chat"}))
        rt.run_until_idle

        graph.objects(type: "principal").size.should eq(1)
      end
    end
  end

  describe "auth_context_builder" do
    it "creates an auth_context snapshotting the principal role" do
      with_identity_runtime do |_store, graph, rt|
        graph.add_object("source", %({"kind":"chat_message","content":"hi","sender_ref":"bob@x.com","channel":"chat"}))
        rt.run_until_idle

        contexts = graph.objects(type: "auth_context")
        contexts.size.should eq(1)
        data = JSON.parse(contexts.first.data)
        data["principal_role"].as_s.should eq("unknown")
        data["channel"].as_s.should eq("chat")

        principal = graph.objects(type: "principal").first
        graph.relations(source: principal.id, type: "authenticated_by")
          .map(&.to_id).should eq([contexts.first.id])
      end
    end

    it "records verified_at for owner principals" do
      with_identity_runtime(settings(%({"owner_identifiers":["alice@example.com"]}))) do |_store, graph, rt|
        graph.add_object("source", %({"kind":"chat_message","content":"hi","sender_ref":"alice@example.com","channel":"chat"}))
        rt.run_until_idle

        contexts = graph.objects(type: "auth_context")
        contexts.size.should eq(1)
        JSON.parse(contexts.first.data)["verified_at"]?.should_not be_nil
      end
    end
  end

  describe "permission_checker" do
    it "marks an owner's low-risk action as permission-checked" do
      with_identity_runtime(settings(%({"owner_identifiers":["alice@example.com"]}))) do |_store, graph, rt|
        graph.add_object("source", %({"kind":"chat_message","content":"hi","sender_ref":"alice@example.com","channel":"chat"}))
        rt.run_until_idle
        principal = graph.objects(type: "principal").first

        graph.add_object("action", JSON.build do |json|
          json.object do
            json.field "kind", "tool_call"
            json.field "description", "Look up CRM data"
            json.field "status", "proposed"
            json.field "risk_class", "low"
            json.field "metadata", {"principal_id" => JSON::Any.new(principal.id)}
          end
        end)
        rt.run_until_idle

        action = graph.objects(type: "action").first
        data = JSON.parse(action.data)
        data["status"].as_s.should eq("proposed")
        data["metadata"].as_h["permission_checked"].as_bool.should be_true
      end
    end

    it "rejects an action from a blocked principal" do
      with_identity_runtime do |_store, graph, rt|
        Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "bad@x.com", "blocked")
        principal = graph.objects(type: "principal").first

        graph.add_object("action", JSON.build do |json|
          json.object do
            json.field "kind", "tool_call"
            json.field "description", "d"
            json.field "status", "proposed"
            json.field "risk_class", "low"
            json.field "metadata", {"principal_id" => JSON::Any.new(principal.id)}
          end
        end)
        rt.run_until_idle

        action = graph.objects(type: "action").first
        data = JSON.parse(action.data)
        data["status"].as_s.should eq("rejected")
        data["metadata"].as_h["rejection_reason"].as_s.should eq("principal_blocked")
      end
    end

    it "rejects a high-risk action from a non-owner/admin principal" do
      with_identity_runtime do |_store, graph, rt|
        Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "ext@x.com", "external")
        principal = graph.objects(type: "principal").first

        graph.add_object("action", JSON.build do |json|
          json.object do
            json.field "kind", "external_write"
            json.field "description", "modify production"
            json.field "status", "proposed"
            json.field "risk_class", "high"
            json.field "metadata", {"principal_id" => JSON::Any.new(principal.id)}
          end
        end)
        rt.run_until_idle

        action = graph.objects(type: "action").first
        data = JSON.parse(action.data)
        data["status"].as_s.should eq("rejected")
        data["metadata"].as_h["rejection_reason"].as_s.should eq("risk_class_high_requires_owner_or_admin")
      end
    end

    it "rejects an execute action from a role without execute" do
      with_identity_runtime do |_store, graph, rt|
        Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "collab@x.com", "collaborator")
        principal = graph.objects(type: "principal").first

        graph.add_object("action", JSON.build do |json|
          json.object do
            json.field "kind", "tool_call"
            json.field "description", "run code"
            json.field "status", "proposed"
            json.field "risk_class", "low"
            json.field "metadata", {"principal_id" => JSON::Any.new(principal.id)}
          end
        end)
        rt.run_until_idle

        action = graph.objects(type: "action").first
        data = JSON.parse(action.data)
        data["status"].as_s.should eq("rejected")
        data["metadata"].as_h["rejection_reason"].as_s.should eq("insufficient_role_for_execute")
      end
    end

    it "skips actions without a principal_id" do
      with_identity_runtime do |_store, graph, rt|
        graph.add_object("action", %({"kind":"tool_call","description":"d","status":"proposed","risk_class":"low","metadata":{}}))
        rt.run_until_idle

        action = graph.objects(type: "action").first
        JSON.parse(action.data)["status"].as_s.should eq("proposed")
      end
    end
  end

  describe "tools" do
    it "checks principal permission with the deterministic decision logic" do
      with_identity_runtime do |_store, graph, _rt|
        Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "a@x.com", "admin")
        Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "b@x.com", "blocked")
        Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "c@x.com", "collaborator")
        principals = graph.objects(type: "principal")
        admin = principals.find { |p| JSON.parse(p.data)["role"].as_s == "admin" }.not_nil!
        blocked = principals.find { |p| JSON.parse(p.data)["role"].as_s == "blocked" }.not_nil!
        collaborator = principals.find { |p| JSON.parse(p.data)["role"].as_s == "collaborator" }.not_nil!

        allow = Chronicle::Packs::IdentityAuth.check_principal_permission_fn(graph, admin.id, "execute", "medium")
        allow.allowed?.should be_true
        allow.reason.should eq("role_allows")

        # Admin qualifies for critical risk (owner or admin required).
        critical_admin = Chronicle::Packs::IdentityAuth.check_principal_permission_fn(graph, admin.id, "execute", "critical")
        critical_admin.allowed?.should be_true

        deny = Chronicle::Packs::IdentityAuth.check_principal_permission_fn(graph, collaborator.id, "execute", "critical")
        deny.allowed?.should be_false
        deny.reason.should eq("risk_class_critical_requires_owner_or_admin")

        blocked_result = Chronicle::Packs::IdentityAuth.check_principal_permission_fn(graph, blocked.id, "read", "low")
        blocked_result.allowed?.should be_false
        blocked_result.reason.should eq("principal_blocked")

        missing = Chronicle::Packs::IdentityAuth.check_principal_permission_fn(graph, "nope", "read", "low")
        missing.reason.should eq("principal_not_found")
      end
    end

    it "registers a principal idempotently and looks it up by ref" do
      with_identity_runtime do |_store, graph, _rt|
        created = Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "alice@example.com", "owner", "Alice")
        created.created?.should be_true
        created.role.should eq("owner")

        again = Chronicle::Packs::IdentityAuth.register_principal_fn(graph, "alice@example.com", "collaborator", "Alice")
        again.created?.should be_false
        again.principal_id.should eq(created.principal_id)
        graph.objects(type: "principal").size.should eq(1)

        found = Chronicle::Packs::IdentityAuth.lookup_principal_fn(graph, "alice@example.com")
        found.should_not be_nil
        found.not_nil!["id"].should eq(created.principal_id)
      end
    end
  end

  describe "fixture: principal_lifecycle" do
    it "runs the full lifecycle deterministically" do
      with_identity_runtime(settings(%({"owner_identifiers":["alice@example.com","alice_slack"],"default_external_role":"external","owner_auth_confidence":0.95}))) do |_store, graph, rt|
        # Owner source -> owner principal + auth_context.
        graph.add_object("source", %({"kind":"chat_message","content":"Please draft a summary.","sender_ref":"alice@example.com","channel":"chat","frame_id":"frame_001"}))
        rt.run_until_idle
        principals = graph.objects(type: "principal")
        auth_contexts = graph.objects(type: "auth_context")
        principals.size.should eq(1)
        owner = principals.first
        JSON.parse(owner.data)["role"].as_s.should eq("owner")
        JSON.parse(owner.data)["auth_confidence"].as_f.should eq(0.95)
        auth_contexts.size.should eq(1)
        JSON.parse(auth_contexts.first.data)["principal_role"].as_s.should eq("owner")

        # External source -> external principal (no new auth context beyond the one).
        graph.add_object("source", %({"kind":"email","content":"Hi, interested in your product.","sender_ref":"vendor@unknown.org","channel":"email","frame_id":"frame_002"}))
        rt.run_until_idle
        externals = graph.objects(type: "principal").select { |p| JSON.parse(p.data)["role"].as_s == "external" }
        externals.size.should eq(1)

        # Owner low-risk action -> permission_checked, not rejected.
        graph.add_object("action", JSON.build do |json|
          json.object do
            json.field "kind", "tool_call"
            json.field "description", "Look up CRM data"
            json.field "status", "proposed"
            json.field "risk_class", "low"
            json.field "metadata", {"principal_id" => JSON::Any.new(owner.id)}
          end
        end)
        rt.run_until_idle
        owner_action = graph.objects(type: "action").first
        owner_action_data = JSON.parse(owner_action.data)
        owner_action_data["status"].as_s.should eq("proposed")
        owner_action_data["metadata"].as_h["permission_checked"].as_bool.should be_true

        # External high-risk action -> rejected.
        graph.add_object("action", JSON.build do |json|
          json.object do
            json.field "kind", "external_write"
            json.field "description", "Modify production data"
            json.field "status", "proposed"
            json.field "risk_class", "high"
            json.field "metadata", {"principal_id" => JSON::Any.new(externals.first.id)}
          end
        end)
        rt.run_until_idle
        blocked_action = graph.objects(type: "action").to_a[-1]
        JSON.parse(blocked_action.data)["status"].as_s.should eq("rejected")

        # Relations present: resolves_to and authenticated_by.
        relation_types = graph.relations.map(&.type).to_set
        relation_types.should contain("resolves_to")
        relation_types.should contain("authenticated_by")
      end
    end
  end
end
