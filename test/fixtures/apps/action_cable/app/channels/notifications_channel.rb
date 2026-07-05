# frozen_string_literal: true

class NotificationsChannel < ActionCable::Channel::Base
  def subscribed
    stream_from "notifications"
  end
end
