# frozen_string_literal: true

require "active_record/orphan_feature"

module ActiveRecord
  class Base
    include Persistence
  end

  module Persistence
  end

  class Relation
    def klass
      ActiveRecord::Base
    end
  end

  class Relation::Batch
  end

  class UnusedRecordFeature
  end
end
