# frozen_string_literal: true

module ObservabilityApp
  class Application < Rails::Application
    config.middleware.use Rack::MiniProfiler
  end
end
