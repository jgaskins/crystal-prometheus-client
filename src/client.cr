require "http/client"
require "json"

require "./error"

module Prometheus
  # A client for the Prometheus HTTP API, for evaluating PromQL queries and
  # exploring metric metadata.
  #
  # ```
  # require "prometheus/client"
  #
  # prometheus = Prometheus::Client.new(URI.parse("http://localhost:9090"))
  #
  # # Range queries always return a matrix
  # prometheus.query_range("rate(http_requests_total[5m])", 1.hour.ago.., step: 1.minute).each do |series|
  #   series.values.each do |sample|
  #     puts "#{series.name} #{sample.time}: #{sample.value}"
  #   end
  # end
  #
  # # The result type of an instant query depends on the expression
  # result = prometheus.query("sum(rate(http_requests_total[5m])) by (job)")
  # if result.is_a? Prometheus::Client::Result::Vector
  #   result.result.each { |v| puts "#{v.metric["job"]}: #{v.value.try(&.value)}" }
  # end
  # ```
  #
  # NOTE: A `Prometheus::Client` instance is not safe to share across fibers. If you need to send
  # concurrent time-series requests, you should use a connection pool, such as
  # [`DB::Pool`](https://crystal-lang.github.io/crystal-db/api/0.14.0/DB/Pool.html):
  #
  # ```
  # require "prometheus/client"
  # require "db/pool"
  #
  # prometheus = DB::Pool.new do
  #   Prometheus::Client.new(URI.parse("http://localhost:9090"))
  # end
  #
  # prometheus.checkout &.query "up"
  # ```
  struct Client
    getter http : HTTP::Client

    def initialize(@http)
    end

    def initialize(uri : URI)
      initialize HTTP::Client.new(uri)
    end

    def close
      http.close
    end

    # Evaluate an instant query. The concrete type of the returned `Result`
    # depends on the expression: selectors and most functions return a
    # `Result::Vector`, range-vector selectors like `up[5m]` return a
    # `Result::Matrix`, and scalar/string expressions return `Result::Scalar`
    # and `Result::StringValue`.
    def query(
      query : String,
      *,
      time : Time | String | Nil = nil,
      timeout : Time::Span? = nil,
      limit : Int? = nil,
    ) : Result
      params = URI::Params{"query" => query}
      set_time_param params, "time", time
      params["timeout"] = duration_param(timeout) if timeout
      params["limit"] = limit.to_s if limit

      post "/api/v1/query", params, as: Result
    end

    # Evaluate a query at each `step` over a range of time. Range queries
    # always return a matrix, so the time series are returned directly. An
    # open-ended range evaluates up to the current time.
    def query_range(
      query : String,
      range : Range(Time | String, Time | String | Nil),
      *,
      step : Time::Span,
      timeout : Time::Span? = nil,
      limit : Int? = nil,
    ) : Array(RangeVector)
      params = URI::Params{"query" => query, "step" => duration_param(step)}
      set_time_param params, "start", range.begin
      set_time_param params, "end", range.end || Time.utc
      params["timeout"] = duration_param(timeout) if timeout
      params["limit"] = limit.to_s if limit

      post("/api/v1/query_range", params, as: Result::Matrix).result
    end

    # List the names of metrics with data in the given time range, optionally
    # restricted to series matching the given selectors.
    def metrics(
      range : Range? = nil,
      *,
      match : String | Array(String) | Nil = nil,
      limit : Int? = nil,
    ) : Array(String)
      label_values "__name__", range, match: match, limit: limit
    end

    # List label names.
    def labels(
      range : Range? = nil,
      *,
      match : String | Array(String) | Nil = nil,
      limit : Int? = nil,
    ) : Array(String)
      get "/api/v1/labels", series_params(range, match, limit), as: Array(String)
    end

    # List the values the given label takes.
    def label_values(
      label : String,
      range : Range? = nil,
      *,
      match : String | Array(String) | Nil = nil,
      limit : Int? = nil,
    ) : Array(String)
      get "/api/v1/label/#{URI.encode_path_segment(label)}/values", series_params(range, match, limit), as: Array(String)
    end

    # List the label sets of series matching the given selectors.
    def series(
      match : String | Array(String),
      range : Range? = nil,
      *,
      limit : Int? = nil,
    ) : Array(Hash(String, String))
      get "/api/v1/series", series_params(range, match, limit), as: Array(Hash(String, String))
    end

    # Fetch metric metadata (type, help text, unit), keyed by metric name.
    def metadata(metric : String? = nil, *, limit : Int? = nil) : Hash(String, Array(Metadata))
      params = URI::Params.new
      params["metric"] = metric if metric
      params["limit"] = limit.to_s if limit
      get "/api/v1/metadata", params, as: Hash(String, Array(Metadata))
    end

    # The envelope every Prometheus API endpoint wraps its payload in.
    struct Response(T)
      include JSON::Serializable

      getter status : Status
      getter data : T?
      @[JSON::Field(key: "errorType")]
      getter error_type : String?
      getter error : String?
      getter warnings : Array(String) { [] of String }
      getter infos : Array(String) { [] of String }

      enum Status
        Success
        Error
      end
    end

    # The `data` payload of `/api/v1/query` and `/api/v1/query_range`. The
    # concrete struct corresponds to the payload's `resultType`.
    abstract struct Result
      include JSON::Serializable

      use_json_discriminator "resultType", {
        matrix: Matrix,
        vector: Vector,
        scalar: Scalar,
        string: StringValue,
      }

      struct Matrix < Result
        getter result : Array(RangeVector)
      end

      struct Vector < Result
        getter result : Array(InstantVector)
      end

      struct Scalar < Result
        getter result : Sample
      end

      struct StringValue < Result
        getter result : StringSample
      end
    end

    # One time series in a matrix result: a label set and the samples
    # recorded for it over the queried range. Native-histogram samples
    # arrive in `histograms` instead of `values`.
    struct RangeVector
      include JSON::Serializable

      getter metric : Hash(String, String)
      getter values : Array(Sample) { [] of Sample }
      getter histograms : Array(HistogramSample) { [] of HistogramSample }

      # The value of the `__name__` label, if present.
      def name : String?
        metric["__name__"]?
      end
    end

    # One time series in a vector result: a label set and the single sample
    # at the evaluated instant. Exactly one of `value` and `histogram` is
    # present, depending on whether the series is a native histogram.
    struct InstantVector
      include JSON::Serializable

      getter metric : Hash(String, String)
      getter value : Sample?
      getter histogram : HistogramSample?

      # The value of the `__name__` label, if present.
      def name : String?
        metric["__name__"]?
      end
    end

    # A single `[timestamp, value]` pair. Prometheus string-encodes values in
    # JSON only so that `NaN`, `+Inf`, and `-Inf` survive transport — they are
    # always float64.
    struct Sample
      getter time : Time
      getter value : Float64

      def initialize(pull : JSON::PullParser)
        pull.read_begin_array
        @time = Time.unix_ms((pull.read_float * 1_000).round.to_i64)
        @value = pull.read_string.to_f64
        pull.read_end_array
      end

      def initialize(@time, @value)
      end
    end

    # A `[timestamp, value]` pair from a string-typed query result.
    struct StringSample
      getter time : Time
      getter value : String

      def initialize(pull : JSON::PullParser)
        pull.read_begin_array
        @time = Time.unix_ms((pull.read_float * 1_000).round.to_i64)
        @value = pull.read_string
        pull.read_end_array
      end

      def initialize(@time, @value)
      end
    end

    # A `[timestamp, histogram]` pair from a native-histogram series.
    struct HistogramSample
      getter time : Time
      getter histogram : Histogram

      def initialize(pull : JSON::PullParser)
        pull.read_begin_array
        @time = Time.unix_ms((pull.read_float * 1_000).round.to_i64)
        @histogram = Histogram.new(pull)
        pull.read_end_array
      end

      def initialize(@time, @histogram)
      end
    end

    # A native-histogram value.
    struct Histogram
      include JSON::Serializable

      @[JSON::Field(converter: Prometheus::Client::FloatString)]
      getter count : Float64
      @[JSON::Field(converter: Prometheus::Client::FloatString)]
      getter sum : Float64
      getter buckets : Array(Bucket) { [] of Bucket }

      # A `[boundary_rule, lower, upper, count]` bucket.
      struct Bucket
        getter boundaries : Boundaries
        getter lower : Float64
        getter upper : Float64
        getter count : Float64

        def initialize(pull : JSON::PullParser)
          pull.read_begin_array
          @boundaries = Boundaries.from_value(pull.read_int)
          @lower = pull.read_string.to_f64
          @upper = pull.read_string.to_f64
          @count = pull.read_string.to_f64
          pull.read_end_array
        end

        # How the bucket's boundaries are to be interpreted.
        enum Boundaries
          OpenLeft   # (lower, upper]
          OpenRight  # [lower, upper)
          OpenBoth   # (lower, upper)
          ClosedBoth # [lower, upper]
        end
      end
    end

    struct Metadata
      include JSON::Serializable

      getter type : String
      getter unit : String
      getter help : String
    end

    # Converter for float64 values that Prometheus string-encodes in JSON.
    module FloatString
      extend self

      def from_json(pull : JSON::PullParser) : Float64
        pull.read_string.to_f64
      end

      def to_json(value : Float64, json : JSON::Builder) : Nil
        json.string value.to_s
      end
    end

    private def post(path : String, params : URI::Params, as type : T.class) : T forall T
      headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
      @http.post path, headers: headers, body: params.to_s do |response|
        handle response, T
      end
    end

    private def get(path : String, params : URI::Params, as type : T.class) : T forall T
      @http.get "#{path}?#{params}" do |response|
        handle response, T
      end
    end

    private def handle(response : HTTP::Client::Response, type : T.class) : T forall T
      body = response.body_io? || IO::Memory.new(response.body)
      if response.success?
        envelope = Response(T).from_json(body)
        case envelope.status
        in .success?
          envelope.data || raise Error.new("Prometheus response contained no data")
        in .error?
          raise Error.new(envelope.error || "Prometheus returned an unspecified error", type: envelope.error_type)
        end
      else
        raise error_from(body.gets_to_end)
      end
    end

    private def error_from(body : String) : Error
      envelope = Response(JSON::Any).from_json(body)
      Error.new(envelope.error || body, type: envelope.error_type)
    rescue JSON::ParseException
      Error.new(body)
    end

    private def set_time_param(params : URI::Params, key : String, time : Time) : Nil
      params[key] = time.to_rfc3339(fraction_digits: 9)
    end

    private def set_time_param(params : URI::Params, key : String, time : String) : Nil
      params[key] = time
    end

    private def set_time_param(params : URI::Params, key : String, time : Nil) : Nil
    end

    # `step` and `timeout` accept either a duration string or a float number
    # of seconds; the float form is the only one that allows fractions.
    private def duration_param(span : Time::Span) : String
      span.total_seconds.to_s
    end

    private def series_params(range : Range?, match : String | Array(String) | Nil, limit : Int?) : URI::Params
      params = URI::Params.new
      params["match[]"] = match if match
      params["limit"] = limit.to_s if limit
      if range
        set_time_param params, "start", range.begin
        set_time_param params, "end", range.end
      end
      params
    end
  end
end
