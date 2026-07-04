# frozen_string_literal: true

module ActionController
  class Base
    include Metal
  end

  module Metal
  end

  class UnusedControllerFeature
  end
end

