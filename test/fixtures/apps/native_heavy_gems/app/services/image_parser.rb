# frozen_string_literal: true

class ImageParser
  def self.call(path, html)
    image = Vips::Image.new_from_file(path)
    document = Nokogiri::HTML(html)

    [image.width, document.text]
  end
end
