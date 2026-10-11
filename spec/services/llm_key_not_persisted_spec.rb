# frozen_string_literal: true

require 'rails_helper'

# LLM Key 不得落盘（开源版）
#
# 这是对外的核心承诺——「服务器不保存 Key」。用可执行断言把它钉住：
#   1. Key 确实被用于 Authorization 头（证明生效，而非被忽略）
#   2. Key 不出现在数据库任何一张表
#   3. Key 不出现在日志输出
#   4. 上游报错时异常消息不回显响应体（消息会进文件日志与用户可见文案）
#   5. 交互日志文件不含 Key，且结构上只有白名单字段
RSpec.describe 'LLM Key 不得落盘', type: :model do
  let(:user_key) { 'sk-user-secret-9f3a7c1e5b2d4f6a8c0e' }
  let(:api_url) { 'https://llm.example/v1/chat/completions' }

  let(:success_response) do
    double('HTTParty::Response',
           success?: true,
           code: 200,
           body: {
             choices: [{ message: { role: 'assistant', content: '好的' }, finish_reason: 'stop' }]
           }.to_json)
  end

  before do
    allow(QingxunConfig).to receive(:llm_api_url).and_return(api_url)
    allow(QingxunConfig).to receive(:llm_model).and_return('test-model')
    LlmApiKey.clear
    # 每个用例用独立的日志根目录，结束后整体删除，避免碰全局日志目录
    @log_dir = Rails.root.join('tmp', "llm_spec_#{SecureRandom.hex(6)}")
    FileUtils.mkdir_p(@log_dir)
    @previous_root = LlmSessionLogger.root
    LlmSessionLogger.root = @log_dir
  end

  after do
    LlmApiKey.clear
    Thread.current[:user_request_context] = nil
    LlmSessionLogger.root = @previous_root
    FileUtils.rm_rf(@log_dir)
  end

  def call_llm
    LlmApiKey.with(user_key) do
      LlmRequestService.call(messages: [{ role: 'user', content: 'hi' }],
                             service_name: 'spec', step_name: 'call')
    end
  end

  def expect_key_absent_from_database(key)
    connection = ActiveRecord::Base.connection
    connection.tables.each do |table|
      connection.select_all(%(SELECT * FROM "#{table}")).each_with_index do |row, index|
        row.each do |column, value|
          raise "#{table}.#{column} 第 #{index + 1} 行泄漏了 Key" if value.to_s.include?(key)
        end
      end
    end
  end

  def capture_logs
    original = Rails.logger
    io = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  describe 'Key 生效性与去向' do
    it '把 Key 放进 Authorization 头发给 LLM' do
      captured = nil
      allow(HTTParty).to receive(:post) do |_url, opts|
        captured = opts
        success_response
      end

      call_llm

      expect(captured[:headers]['Authorization']).to eq("Bearer #{user_key}")
    end

    it '调用完成后 Key 不出现在数据库的任何一张表里' do
      allow(HTTParty).to receive(:post).and_return(success_response)
      call_llm
      expect_key_absent_from_database(user_key)
    end

    it 'Key 不出现在日志输出中' do
      allow(HTTParty).to receive(:post).and_return(success_response)
      logs = capture_logs { call_llm }
      expect(logs).not_to include(user_key)
    end

    it '交互日志文件不含 Key，且只含白名单字段' do
      Thread.current[:user_request_context] = { request_id: SecureRandom.uuid }
      allow(HTTParty).to receive(:post).and_return(success_response)

      call_llm

      dir = LlmSessionLogger.session_dir_for(Thread.current[:user_request_context][:request_id])
      expect(dir).not_to be_nil
      files = Dir.glob(File.join(dir.to_s, '*')).select { |p| File.file?(p) && File.basename(p) != '_session.json' }
      expect(files).not_to be_empty

      files.each do |path|
        content = File.read(path)
        expect(content).not_to include(user_key)
        content.scan(/\{[^\n]*\}/).each do |fragment|
          expect(fragment).not_to include('Authorization')
          expect(fragment).not_to include('api_key')
        end
      end
    end
  end

  describe '异常脱敏' do
    let(:error_body) do
      { error: { type: 'invalid_request_error', code: 'bad', message: "key #{user_key} rejected" } }.to_json
    end

    let(:error_response) do
      double('HTTParty::Response', success?: false, code: 400, body: error_body)
    end

    it '上游报错时异常消息不回显响应体' do
      allow(HTTParty).to receive(:post).and_return(error_response)

      expect { call_llm }.to raise_error do |error|
        expect(error.message).not_to include(user_key)
        expect(error.message).not_to include('rejected')
      end
    end
  end
end
