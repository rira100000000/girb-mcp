class HealthController < ApplicationController
  def show
    render json: {
      status: "ok",
      rails_version: Rails::VERSION::STRING,
      ruby_version: RUBY_VERSION,
      environment: Rails.env,
      time: Time.current.iso8601
    }
  end
end
