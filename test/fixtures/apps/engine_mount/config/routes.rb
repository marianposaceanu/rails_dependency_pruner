# frozen_string_literal: true

Rails.application.routes.draw do
  mount Admin::Engine, at: "/admin"
end
