module Prometheus
  class Error < Exception
    # The `errorType` reported by the Prometheus API, when the error came
    # from an API error response.
    getter type : String?

    def initialize(message : String? = nil, *, @type : String? = nil)
      super message
    end
  end
end
