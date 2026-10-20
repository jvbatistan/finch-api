module ProductionSecretValidation
  class MissingSecretError < StandardError; end

  module_function

  def validate!(environment:, application:)
    return unless environment.to_s == "production"

    # Rails resolves SECRET_KEY_BASE, then credentials.secret_key_base, then
    # legacy config/secrets. Validate the value actually used for signed cookies.
    secret = begin
      application.secret_key_base
    rescue StandardError
      # Do not chain an underlying exception that may include configuration.
      raise MissingSecretError, "Production requires a valid SECRET_KEY_BASE or Rails credentials secret_key_base.", cause: nil
    end
    return if secret.is_a?(String) && !secret.strip.empty?

    raise MissingSecretError, "Production requires a valid SECRET_KEY_BASE or Rails credentials secret_key_base."
  end
end
