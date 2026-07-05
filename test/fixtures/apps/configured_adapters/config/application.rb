# frozen_string_literal: true

module ConfiguredAdaptersApp
  class Application < Rails::Application
    config.active_job.queue_adapter = :sidekiq
    config.action_mailer.delivery_method = :smtp
    config.active_storage.service = :local
    config.action_cable.mount_path = "/cable"
  end
end
