require "json"
require "time"

module Chronicle::Packs::Email
  # Email tools. Ported from upstream packs/email/tools.py.
  #
  # The `*_fn` functions are the ported behavior and take the graph
  # explicitly. The declared Chronicle::Tool wrappers read a graph bound by
  # the host via `bound_graph` (chronicle's Tool model is args-only).

  # The graph the declared tools operate on.
  class_property bound_graph : Chronicle::GraphProjection? = nil

  def self._now_iso : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  # Inject a raw email into the graph. Returns the EmailMessage object.
  def self.ingest_email_fn(
    graph : Chronicle::GraphProjection,
    message_id : String,
    from_addr : String,
    to_addrs : Array(String),
    subject : String,
    body_text : String,
    cc_addrs : Array(String)? = nil,
    thread_id : String? = nil,
    in_reply_to : String? = nil,
    references : Array(String)? = nil,
    received_at : String? = nil,
    body_html : String? = nil,
    headers : Hash(String, String)? = nil,
  ) : Chronicle::GraphObject
    graph.add_object("email_message", EmailMessage.new(
      message_id: message_id,
      from_addr: from_addr,
      to_addrs: to_addrs,
      cc_addrs: cc_addrs || [] of String,
      subject: subject,
      body_text: body_text,
      body_html: body_html,
      thread_id: thread_id,
      in_reply_to: in_reply_to,
      references: references || [] of String,
      received_at: received_at || _now_iso,
      headers: headers || {} of String => String,
    ).to_json, actor: "email")
  end

  # Create a CommResponseCandidate for an email, triggering reply_drafter +
  # send_approver. Returns the candidate object.
  def self.create_email_response_fn(
    graph : Chronicle::GraphProjection,
    comm_message_id : String,
    content : String,
    channel : String = "email",
    status : String = "draft",
    artifact_id : String? = nil,
    thread_id : String? = nil,
  ) : Chronicle::GraphObject
    graph.add_object("comm_response_candidate", {
      "message_id"          => JSON::Any.new(comm_message_id),
      "thread_id"           => JSON::Any.new(thread_id),
      "channel"             => JSON::Any.new(channel),
      "content"             => JSON::Any.new(content),
      "artifact_id"         => JSON::Any.new(artifact_id),
      "status"              => JSON::Any.new(status),
      "created_by_behavior" => JSON::Any.new("manual"),
    }.to_json, actor: "email")
  end

  private def self.bound_graph_or_raise : Chronicle::GraphProjection
    bound_graph || raise Chronicle::Packs::PackError.new(
      "email tools require a bound graph (set Email.bound_graph)"
    )
  end

  # ---- declared tool bodies (args-only chronicle Tool model) -----------

  @[Chronicle::Packs::Annotations::Tool(name: "ingest_email", description: "Inject a raw email into the graph. Creates EmailMessage → triggers email_ingester → Source(kind=email) + CommMessage(channel=email) + EmailThread.", deterministic: true)]
  def ingest_email_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = ingest_email_fn(
      bound_graph_or_raise,
      input["message_id"]?.try(&.as_s?) || "",
      input["from_addr"]?.try(&.as_s?) || "",
      input["to_addrs"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
      input["subject"]?.try(&.as_s?) || "",
      input["body_text"]?.try(&.as_s?) || "",
      cc_addrs: input["cc_addrs"]?.try(&.as_a?.try(&.map(&.as_s))),
      thread_id: input["thread_id"]?.try(&.as_s?),
      in_reply_to: input["in_reply_to"]?.try(&.as_s?),
      received_at: input["received_at"]?.try(&.as_s?),
      body_html: input["body_html"]?.try(&.as_s?),
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end

  @[Chronicle::Packs::Annotations::Tool(name: "create_email_response", description: "Create a CommResponseCandidate for an email. Triggers reply_drafter → EmailDraft, then send_approver → approval gate or auto-approve.", deterministic: true)]
  def create_email_response_tool(args : String) : String
    input = JSON.parse(args).as_h
    result = create_email_response_fn(
      bound_graph_or_raise,
      input["comm_message_id"]?.try(&.as_s?) || "",
      input["content"]?.try(&.as_s?) || "",
      status: input["status"]?.try(&.as_s?) || "draft",
    )
    {"id" => JSON::Any.new(result.id)}.to_json
  end
end
