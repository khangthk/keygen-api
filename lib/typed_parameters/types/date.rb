# frozen_string_literal: true

module TypedParameters
  module Types
    register(:date,
      coerce: -> v { v.to_date },
      match: -> v { v.is_a?(Date) },
    )
  end
end