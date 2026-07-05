# frozen_string_literal: true

class Photo < ActiveRecord::Base
  has_one_attached :image
end
