require "json"

module Chronicle::Packs::ToolGateway
  # Output sanitizer for Tool Gateway Pack. Ported from upstream
  # packs/tool_gateway/sanitizer.py. Strips common sensitive patterns from
  # capability result output before storing in CapabilityResult and sourcing
  # to Core. All matches are replaced with [REDACTED:<reason>] so the
  # redaction is visible — silent stripping would hide data loss.

  module Sanitizer
    PRIVATE_KEY_RE     = /-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----/m
    AWS_KEY_RE         = /\bAKIA[0-9A-Z]{16}\b/
    API_KEY_RE         = /\b(sk|pk|rk|ak|sk_live|sk_test|pk_live|pk_test)-[a-zA-Z0-9_\-]{20,}/
    BEARER_RE          = /(Bearer\s+|"?authorization"?\s*:\s*"?Bearer\s+)[a-zA-Z0-9_=+\/-]{20,}/i
    HEX_TOKEN_RE       = /\b[0-9a-fA-F]{32,}\b/
    SENSITIVE_FIELD_RE = /"(password|secret|token|api_key|apikey|access_token|refresh_token|private_key)"\s*:\s*"[^"]{4,}"/i

    # Sanitize a capability result output string. Returns the cleaned text
    # and whether at least one pattern was redacted.
    def self.sanitize_output(text : String) : {String, Bool}
      result = text
      result = result.gsub(PRIVATE_KEY_RE, "[REDACTED:private_key_block]")
      result = result.gsub(AWS_KEY_RE, "[REDACTED:aws_access_key]")
      result = result.gsub(API_KEY_RE, "[REDACTED:api_key]")
      result = result.gsub(BEARER_RE, "[REDACTED:bearer_token]")
      result = result.gsub(HEX_TOKEN_RE, "[REDACTED:hex_token]")
      result = result.gsub(SENSITIVE_FIELD_RE, "[REDACTED:sensitive_field]")
      {result, result != text}
    end
  end
end
