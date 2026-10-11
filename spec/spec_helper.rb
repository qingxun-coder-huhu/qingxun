# frozen_string_literal: true

# 确保测试环境
ENV['RAILS_ENV'] = 'test'

# 加载项目文件
require 'bundler/setup'
Bundler.require(:default)

# 加载被测试的库
require_relative '../lib/telnet_device'

RSpec.configure do |config|
  # 启用 expect 语法
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  # 模拟框架配置
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # 限制测试只运行匹配过滤器的测试
  config.filter_run :focus
  config.run_all_when_everything_filtered = true

  # 打印运行时间较长的测试
  config.profile_examples = 10

  # 默认排序
  config.order = :random

  # 种子值，用于随机排序
  Kernel.srand config.seed
end