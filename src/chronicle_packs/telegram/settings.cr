require "json"

module Chronicle::Packs::Telegram
  # Settings for the Telegram Adapter Pack. Ported from upstream
  # packs/telegram/settings.py (TelegramSettings).
  struct TelegramSettings
    include JSON::Serializable
    include Chronicle::Packs::SettingsSchema

    getter credential_name : String = "TELEGRAM_BOT_TOKEN"
    getter outbound_risk_class : String = "low"
    getter api_base : String = "https://api.telegram.org"

    def initialize(
      @credential_name : String = "TELEGRAM_BOT_TOKEN",
      @outbound_risk_class : String = "low",
      @api_base : String = "https://api.telegram.org",
    )
    end
  end
end
