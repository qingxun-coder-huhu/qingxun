# frozen_string_literal: true

module Qingxun
  module Integrations
    class << self
      attr_accessor :mode

      def server?
        mode == :server
      end

      def client?
        mode == :client
      end
    end

    self.mode = :server
  end
end

require_relative "integrations/base"
require_relative "integrations/custom"
