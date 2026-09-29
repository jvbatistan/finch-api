# frozen_string_literal: true

# The E2E server receives its approved environment from its launcher. Loading
# ignored dotenv files here could reintroduce DATABASE_URL before Rails reads
# config/database.yml.
require 'logger'
require 'rails'
require 'dotenv/rails'

Dotenv::Railtie.instance.define_singleton_method(:load) {}
