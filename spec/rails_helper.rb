# frozen_string_literal: true

# Rails 集成测试辅助文件
#
# 说明：
#   项目原有的 spec 多为「不加载 Rails 的纯 Ruby 单测」（如 user_client_code_spec 的部分用例），
#   它们依赖 .rspec 中自动引入的 spec_helper。
#
#   本文件用于需要真实数据库与真实模型的测试（识别码、请求链路等），显式 require 即可：
#     require 'rails_helper'
#
# 隐性知识：
#   测试库为 PostgreSQL，database.yml 中 host 默认走 TCP 且需要密码；
#   本机需以 DATABASE_HOST=/var/run/postgresql 走 unix socket 才能连上。
ENV['RAILS_ENV'] = 'test'

require_relative '../config/environment'
require 'rspec/rails'

# LLM 交互日志在测试期改写到 tmp：否则单测会把 no-request-* 之类的垃圾写进真实 logs/。
LlmSessionLogger.root = Rails.root.join('tmp', 'test_llm_sessions')

RSpec.configure do |config|
  # 每个用例跑在事务里并回滚，保证用例之间互不污染
  config.use_transactional_fixtures = true

  # 按目录推断 spec 类型（spec/requests → request spec 等）
  config.infer_spec_type_from_file_location!

  # 过滤 Rails 内部栈帧，让失败信息聚焦在业务代码
  config.filter_rails_from_backtrace!
end
