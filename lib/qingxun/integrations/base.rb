# frozen_string_literal: true

module Qingxun
  module Integrations
    class Base
      attr_accessor :config, :logger

      def initialize(config: {}, logger: nil)
        @config = config
        @logger = logger || Logger.new(STDOUT)
      end
    end
  end
end
