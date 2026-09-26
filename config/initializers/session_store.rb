Rails.application.config.session_store :cookie_store,
  key: "_controle_de_gastos_session",
  same_site: :lax,
  secure: Rails.env.production?
