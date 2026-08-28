require "json"

module Chronicle::Packs::WhatsApp
  # Settings for the WhatsApp Adapter Pack (Meta Cloud API). Ported from
  # upstream packs/whatsapp/settings.py (WhatsAppSettings).
  struct WhatsAppSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter credential_name : String = "WHATSAPP_ACCESS_TOKEN"
    getter phone_number_id : String? = nil
    getter outbound_risk_class : String = "low"
    getter api_base : String = "https://graph.facebook.com/v20.0"

    def initialize(
      @credential_name : String = "WHATSAPP_ACCESS_TOKEN",
      @phone_number_id : String? = nil,
      @outbound_risk_class : String = "low",
      @api_base : String = "https://graph.facebook.com/v20.0",
    )
    end
  end
end
