require "./spec_helper"
require "hot_topic"

require "../src/client"

describe Prometheus::Client do
  describe "#query_range" do
    it "queries a range of metrics" do
      latest_ts = 1.minute.ago.at_beginning_of_second
      http = server("POST", "/api/v1/query_range", {
        status: "success",
        data:   {
          resultType: "matrix",
          result:     [
            {
              metric: {
                __name__:   "http_request_duration",
                method:     "GET",
                controller: "articles",
                action:     "show",
              },
              values: [
                {latest_ts.to_unix_f, "123"},
                {(latest_ts - 1.minute).to_unix_f, "456"},
              ],
            },
          ],
        },
      })
      client = Prometheus::Client.new(http)

      results = client.query_range("asdf", 1.hour.ago.., step: 1.minute)

      series = results.first
      series.name.should eq "http_request_duration"
      series.metric["method"].should eq "GET"

      latest, earliest = series.values

      latest.time.should eq latest_ts
      latest.value.should eq 123

      earliest.time.should eq latest_ts - 1.minute
      earliest.value.should eq 456
    end
  end

  describe "#query" do
    it "returns a vector for instant-vector expressions" do
      ts = 1.minute.ago.at_beginning_of_second
      http = server("POST", "/api/v1/query", {
        status: "success",
        data:   {
          resultType: "vector",
          result:     [
            {
              metric: {__name__: "up", job: "prometheus"},
              value:  {ts.to_unix_f, "1"},
            },
          ],
        },
      })
      client = Prometheus::Client.new(http)

      result = client.query("up")

      result = result.should be_a Prometheus::Client::Result::Vector
      vector = result.result.first
      vector.name.should eq "up"
      sample = vector.value.not_nil!
      sample.time.should eq ts
      sample.value.should eq 1
    end

    it "returns a scalar for scalar expressions, including NaN" do
      ts = 1.minute.ago.at_beginning_of_second
      http = server("POST", "/api/v1/query", {
        status: "success",
        data:   {
          resultType: "scalar",
          result:     {ts.to_unix_f, "NaN"},
        },
      })
      client = Prometheus::Client.new(http)

      result = client.query("0 / 0")

      result = result.should be_a Prometheus::Client::Result::Scalar
      result.result.time.should eq ts
      result.result.value.nan?.should be_true
    end

    it "returns a string for string expressions" do
      ts = 1.minute.ago.at_beginning_of_second
      http = server("POST", "/api/v1/query", {
        status: "success",
        data:   {
          resultType: "string",
          result:     {ts.to_unix_f, "hello"},
        },
      })
      client = Prometheus::Client.new(http)

      result = client.query(%("hello"))

      result = result.should be_a Prometheus::Client::Result::StringValue
      result.result.value.should eq "hello"
    end

    it "raises Prometheus::Error for API error responses" do
      http = HotTopic.new do |context|
        context.response.status = :bad_request
        {
          status:    "error",
          errorType: "bad_data",
          error:     %(1:4: parse error: unexpected end of input inside braces),
        }.to_json context.response
      end
      client = Prometheus::Client.new(http)

      error = expect_raises Prometheus::Error, /parse error/ do
        client.query("up{")
      end
      error.type.should eq "bad_data"
    end
  end
end

def server(method : String, path : String, body)
  HotTopic.new do |context|
    case {context.request.method, context.request.path}
    when {method, path}
      body.to_json context.response
    else
      raise "Unexpected request: #{context.request}"
    end
  end
end
