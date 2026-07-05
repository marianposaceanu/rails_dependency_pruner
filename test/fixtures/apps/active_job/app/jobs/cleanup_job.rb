# frozen_string_literal: true

class CleanupJob < ActiveJob::Base
  queue_as :default
end
