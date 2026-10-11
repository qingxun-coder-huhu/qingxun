# frozen_string_literal: true

require 'rails_helper'

# QingxunConfig：从 config/qingxun.yml 读取业务配置
#
# 重点钉住"改完配置文件无需重启即可生效"——否则使用者会以为 Key 没起作用。
RSpec.describe QingxunConfig do
  let(:path) { Rails.root.join('config', 'qingxun.yml') }

  around do |example|
    backup = File.exist?(path) ? File.read(path) : nil
    described_class.reload!
    example.run
  ensure
    if backup
      File.write(path, backup)
    elsif File.exist?(path)
      File.delete(path)
    end
    described_class.reload!
  end

  it '修改配置文件后无需重启即可生效' do
    File.write(path, "#{Rails.env}:\n  llm:\n    api_key: sk-one-1111111111111111\n")
    expect(described_class.llm_api_key).to eq('sk-one-1111111111111111')

    sleep 1.1 # 确保 mtime 变化
    File.write(path, "#{Rails.env}:\n  llm:\n    api_key: sk-two-2222222222222222\n")
    expect(described_class.llm_api_key).to eq('sk-two-2222222222222222')
  end

  it '未配置时回落到默认端点与模型' do
    File.delete(path) if File.exist?(path)
    described_class.reload!

    expect(described_class.llm_api_key).to be_nil
    expect(described_class.llm_api_url).to eq(described_class::DEFAULT_LLM_API_URL)
    expect(described_class.llm_model).to eq(described_class::DEFAULT_LLM_MODEL)
  end

  it '环境变量可作为回退来源' do
    File.delete(path) if File.exist?(path)
    described_class.reload!
    ENV['QINGXUN_LLM_API_KEY'] = 'sk-from-env-333333333333333'
    expect(described_class.llm_api_key).to eq('sk-from-env-333333333333333')
  ensure
    ENV.delete('QINGXUN_LLM_API_KEY')
    described_class.reload!
  end
end
