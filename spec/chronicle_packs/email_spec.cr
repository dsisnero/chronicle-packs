require "spec"
require "../spec_helper"

# Email Pack (packs/email): inbound/outbound email adapter. Translated from
# upstream packs/email/* (revision
# 6639a5385518ad49f74813373c85cf96eff9adc0). email_ingester turns
# email_message into Source + CommMessage(channel=email) + EmailThread;
# reply_drafter formats CommResponseCandidate → EmailDraft; send_approver
# gates external sends with owner approval.

module EmailSpecSupport
  extend self

  REPO = Path[__DIR__].parent.parent

  def email_manifest_path : Path
    REPO / "vendor" / "activegraph-packs" / "packs" / "email" / "manifest.toml"
  end

  # A runtime with Core + Communication + Email loaded. Mirrors upstream
  # _make_runtime (owner_emails default alice@example.com).
  def with_email_runtime(
    owner_emails : Array(String)? = nil,
    require_approval : Bool = true,
    trusted_domains : Array(String)? = nil,
    &
  )
    store, graph, rt = PackSpecRuntime.runtime
    rt.load_pack(Chronicle::Packs::Core.pack).should be_true
    rt.load_pack(Chronicle::Packs::Communication.pack).should be_true
    settings = Chronicle::Packs::Email::EmailSettings.new(
      owner_email_addresses: owner_emails || ["alice@example.com"],
      require_approval_for_external: require_approval,
      trusted_domains: trusted_domains || [] of String,
    )
    rt.load_pack(Chronicle::Packs::Email.pack, JSON.parse(settings.to_json).as_h).should be_true

    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Email.clear_email_registry
    yield store, graph, rt
  ensure
    Chronicle::Packs::Communication.clear_thread_registry
    Chronicle::Packs::Email.clear_email_registry
  end

  def ingest(graph, message_id : String, from_addr : String, to_addrs : Array(String), subject : String, body_text : String, received_at : String? = nil, in_reply_to : String? = nil, thread_id : String? = nil)
    Chronicle::Packs::Email.ingest_email_fn(
      graph, message_id: message_id, from_addr: from_addr, to_addrs: to_addrs,
      subject: subject, body_text: body_text, received_at: received_at,
      in_reply_to: in_reply_to, thread_id: thread_id
    )
  end

  def respond(graph, comm_message_id : String, content : String)
    Chronicle::Packs::Email.create_email_response_fn(graph, comm_message_id: comm_message_id, content: content)
  end
end

include EmailSpecSupport

describe Chronicle::Packs::Email do
  describe "manifest-declared surface" do
    it "matches the upstream email manifest" do
      pack = Chronicle::Packs::Email.pack
      pack.name.should eq("email")
      pack.version.should eq("0.1.2")
      pack.object_types.map(&.name).should eq(
        ["email_message", "email_thread", "email_draft"]
      )
      pack.relation_types.map(&.name).should eq(
        ["email_thread_contains", "draft_responds_to", "draft_from_candidate", "email_linked_to_comm_thread"]
      )
      pack.behaviors.map(&.name).should eq(
        ["email_ingester", "reply_drafter", "send_approver"]
      )
      pack.tools.map(&.name).should eq(["ingest_email", "create_email_response"])
      pack.settings_schema.should eq("EmailSettings")
    end

    it "passes the runtime-side surface check against the real manifest" do
      manifest = Chronicle::Packs.load_manifest(email_manifest_path.to_s)
      Chronicle::Packs.verify_surface(manifest, Chronicle::Packs::Email.pack)
    end
  end

  describe "email_ingester" do
    it "translates an inbound email into Source + CommMessage + EmailThread" do
      with_email_runtime do |_store, graph, rt|
        ingest(graph,
          message_id: "<msg001@mail.sequoia.com>",
          from_addr: "sarah.thompson@sequoia.com",
          to_addrs: ["alice@example.com"],
          subject: "Investment interest in Northwind AI",
          body_text: "Hi Alice, I'd love to schedule a call about Northwind AI.",
          received_at: "2026-06-03T09:00:00Z",
        )
        rt.run_until_idle

        sources = graph.objects(type: "source")
        sources.size.should eq(1)
        JSON.parse(sources.first.data)["kind"].as_s.should eq("email")
        JSON.parse(sources.first.data)["channel"].as_s.should eq("email")

        comm_msgs = graph.objects(type: "comm_message")
        comm_msgs.size.should eq(1)
        cm = JSON.parse(comm_msgs.first.data)
        cm["channel"].as_s.should eq("email")
        cm["direction"].as_s.should eq("inbound")
        cm["sender_ref"].as_s.should eq("sarah.thompson@sequoia.com")

        threads = graph.objects(type: "email_thread")
        threads.size.should eq(1)
        JSON.parse(threads.first.data)["subject"].as_s.should eq("Investment interest in Northwind AI")
      end
    end

    it "produces a comm_intent via communication intent_detector" do
      with_email_runtime do |_store, graph, rt|
        ingest(graph,
          message_id: "<msg001@mail.sequoia.com>",
          from_addr: "sarah.thompson@sequoia.com",
          to_addrs: ["alice@example.com"],
          subject: "Investment interest in Northwind AI",
          body_text: "Could you please share your latest deck?",
          received_at: "2026-06-03T09:00:00Z",
        )
        rt.run_until_idle

        intents = graph.objects(type: "comm_intent")
        intents.size.should be >= 1
      end
    end

    it "links follow-ups into the same EmailThread via In-Reply-To" do
      with_email_runtime do |_store, graph, rt|
        ingest(graph,
          message_id: "<original@mail.example.com>",
          from_addr: "founder@startup.com",
          to_addrs: ["alice@example.com"],
          subject: "Partnership proposal",
          body_text: "Hi Alice, interested in partnering.",
          received_at: "2026-06-01T08:00:00Z",
        )
        rt.run_until_idle

        threads_after_first = graph.objects(type: "email_thread")
        threads_after_first.size.should eq(1)

        ingest(graph,
          message_id: "<reply001@mail.example.com>",
          from_addr: "alice@example.com",
          to_addrs: ["founder@startup.com"],
          subject: "Re: Partnership proposal",
          body_text: "Hi, let's schedule a call.",
          in_reply_to: "<original@mail.example.com>",
          thread_id: "<original@mail.example.com>",
          received_at: "2026-06-01T10:00:00Z",
        )
        rt.run_until_idle

        threads_after_reply = graph.objects(type: "email_thread")
        threads_after_reply.size.should eq(1)

        data = JSON.parse(threads_after_reply.first.data)
        data["message_count"].as_i.should eq(2)
      end
    end

    it "dedups emails with the same message_id" do
      with_email_runtime do |_store, graph, rt|
        2.times do
          ingest(graph,
            message_id: "<dedup-test@mail.example.com>",
            from_addr: "sender@example.com",
            to_addrs: ["alice@example.com"],
            subject: "Dedup test",
            body_text: "This email arrives twice (webhook retry).",
          )
          rt.run_until_idle
        end

        graph.objects(type: "source").size.should eq(1)
        graph.objects(type: "comm_message").size.should eq(1)
        graph.objects(type: "email_thread").size.should eq(1)
      end
    end
  end

  describe "reply_drafter + send_approver" do
    it "gates an external recipient with an approval_request action" do
      with_email_runtime(owner_emails: ["alice@example.com"], require_approval: true) do |_store, graph, rt|
        ingest(graph,
          message_id: "<founder-msg@mail.vc.com>",
          from_addr: "investor@venturecap.com",
          to_addrs: ["alice@example.com"],
          subject: "Term sheet ready",
          body_text: "Alice, we have a term sheet ready.",
        )
        rt.run_until_idle

        comm_msgs = graph.objects(type: "comm_message")
        comm_msgs.size.should eq(1)
        comm_msg_id = comm_msgs.first.id

        respond(graph, comm_msg_id, "Thank you for the term sheet. I'll review it.")
        rt.run_until_idle

        drafts = graph.objects(type: "email_draft")
        drafts.size.should eq(1)
        draft_data = JSON.parse(drafts.first.data)
        draft_data["status"].as_s.should eq("draft")
        draft_data["requires_approval"].as_bool.should be_true

        approval_actions = graph.objects(type: "action").select do |a|
          JSON.parse(a.data)["kind"]?.try(&.as_s?) == "approval_request"
        end
        approval_actions.size.should be >= 1
        JSON.parse(approval_actions.first.data)["risk_class"].as_s.should eq("high")
      end
    end

    it "auto-approves (sends) an internal owner-to-owner reply" do
      with_email_runtime(
        owner_emails: ["alice@example.com", "alice.internal@example.com"],
        require_approval: true,
      ) do |_store, graph, rt|
        ingest(graph,
          message_id: "<internal-msg@example.com>",
          from_addr: "alice.internal@example.com",
          to_addrs: ["alice@example.com"],
          subject: "Internal note",
          body_text: "Alice, just a quick internal note.",
        )
        rt.run_until_idle

        comm_msg_id = graph.objects(type: "comm_message").first.id

        respond(graph, comm_msg_id, "Got it, thanks.")
        rt.run_until_idle

        drafts = graph.objects(type: "email_draft")
        drafts.size.should eq(1)
        JSON.parse(drafts.first.data)["status"].as_s.should eq("sent")

        approval_actions = graph.objects(type: "action").select do |a|
          JSON.parse(a.data)["kind"]?.try(&.as_s?) == "approval_request"
        end
        approval_actions.size.should eq(0)
      end
    end

    it "formats the draft with Re: subject and the original sender" do
      with_email_runtime(owner_emails: ["alice@example.com"], require_approval: true) do |_store, graph, rt|
        ingest(graph,
          message_id: "<msg1@example.com>",
          from_addr: "external@other.com",
          to_addrs: ["alice@example.com"],
          subject: "Re: Fwd: Hello",
          body_text: "Hello there.",
          received_at: "2026-06-03T09:00:00Z",
        )
        rt.run_until_idle

        comm_msg_id = graph.objects(type: "comm_message").first.id
        respond(graph, comm_msg_id, "Hi back!")
        rt.run_until_idle

        draft = graph.objects(type: "email_draft").first
        data = JSON.parse(draft.data)
        data["to_addrs"].as_a.map(&.as_s).should eq(["external@other.com"])
        data["subject"].as_s.should eq("Re: Hello")
      end
    end
  end
end
