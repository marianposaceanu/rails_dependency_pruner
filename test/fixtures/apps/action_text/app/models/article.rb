# frozen_string_literal: true

class Article < ActiveRecord::Base
  has_rich_text :body
end
