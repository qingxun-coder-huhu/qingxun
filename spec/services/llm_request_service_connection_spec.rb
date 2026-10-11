# frozen_string_literal: true

require 'rails_helper'

# LLM 调用期间的数据库连接占用（端到端钉住出口）
#
# 背景（实测）：AI 请求从头到尾占着一条数据库连接，而其中 40 秒（上限 300 秒）纯粹在等
# DeepSeek 返回。pool 默认 5 个连接，于是"能同时跑几个生成"实际由连接池决定；池满时第 6 个
# 线程等 5 秒后抛 ActiveRecord::ConnectionTimeoutError（500）。这里钉住：
# 发请求前连接已经还回池子，且调用结束后数据库照常可用。
RSpec.describe 'LLM 调用期间的数据库连接' do
  self.use_transactional_tests = false

  let(:ok_response) do
    double('HTTParty::Response', success?: true, code: 200,
                                 body: { choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }] }.to_json)
  end

  around do |example|
    LlmApiKey.clear
    example.run
  ensure
    LlmApiKey.clear
  end

  def call_llm
    LlmApiKey.with('sk-users-own-deepseek-key-1234567890abcd') do
      LlmRequestService.call(messages: [{ role: 'user', content: '你好' }])
    end
  end

  it '等上游返回期间不占着连接，返回后数据库仍可用' do
    ActiveRecord::Base.connection   # 模拟请求开头已查过库（application_controller#current_user）
    busy_while_waiting = nil

    allow(HTTParty).to receive(:post) do |*_args|
      busy_while_waiting = ActiveRecord::Base.connection_pool.stat[:busy]
      ok_response
    end

    call_llm

    expect(busy_while_waiting).to eq(0)
    expect(ActiveRecord::Base.connection_pool.active_connection?).to be_nil,
                                                                   '调用结束后不该在等上游的那一段又占着连接'
    expect(User.count).to be_a(Integer)  # 下次访问数据库自动借出
  end
end
