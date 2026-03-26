# frozen_string_literal: true

require "somfy_sdn"
require "sdn/cli/mqtt"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.before do
    logger = instance_double(Logger, debug: nil, info: nil, warn: nil, error: nil, fatal: nil)
    allow(SDN).to receive(:logger).and_return(logger)
  end
end
