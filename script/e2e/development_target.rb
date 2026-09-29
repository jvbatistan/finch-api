# frozen_string_literal: true

require 'uri'

module E2EDevelopmentTarget
  class UnsafeTargetError < StandardError; end

  APPROVED_DATABASE = '/finch_api_development'
  APPROVED_PORT = 5432
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1]].freeze

  module_function

  def validate!(url)
    uri = URI.parse(url.to_s)
    allowed = %w[postgres postgresql].include?(uri.scheme.to_s.downcase) &&
              LOOPBACK_HOSTS.include?(uri.host.to_s.downcase) &&
              uri.port == APPROVED_PORT && uri.path == APPROVED_DATABASE &&
              uri.query.nil? && uri.fragment.nil?
    raise UnsafeTargetError, 'E2E requires the approved local development target.' unless allowed

    uri
  rescue URI::InvalidURIError, ArgumentError
    raise UnsafeTargetError, 'E2E requires the approved local development target.'
  end

  def run_cli!
    validate!(ENV['DATABASE_URL_DEVEL'])
  rescue UnsafeTargetError
    warn 'E2E requires the approved local development target.'
    exit 1
  end
end
