# frozen_string_literal: true

class UserMailer < ActionMailer::Base
  def welcome
    mail(to: "test@example.org")
  end
end
