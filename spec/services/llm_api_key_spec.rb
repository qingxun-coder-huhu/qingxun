# frozen_string_literal: true

require 'rails_helper'

# LlmApiKey 测试（开源版）
#
# 覆盖重点：
#   1. Key 的解析顺序（显式 → 请求级 → 配置文件）
#   2. 作用域结束后必定清除（含异常路径）——防止 Key 在线程复用时泄漏到下一个请求
RSpec.describe LlmApiKey do
  around do |example|
    example.run
  ensure
    described_class.clear
  end

  describe '.with' do
    it '块内可读到 Key' do
      described_class.with('sk-request-level') do
        expect(described_class.current).to eq('sk-request-level')
      end
    end

    it '块结束后清除 Key' do
      described_class.with('sk-request-level') { nil }
      expect(described_class.current).to be_nil
    end

    # 这条最重要：after_action 在异常时不会执行，若用 after_action 清除，
    # Key 会残留到同一线程的下一个请求里。
    it '块内抛异常时同样清除 Key' do
      expect do
        described_class.with('sk-request-level') { raise 'boom' }
      end.to raise_error('boom')

      expect(described_class.current).to be_nil
    end

    it '嵌套使用时恢复外层值，而不是直接清空' do
      described_class.with('sk-outer') do
        described_class.with('sk-inner') do
          expect(described_class.current).to eq('sk-inner')
        end
        expect(described_class.current).to eq('sk-outer')
      end
    end

    it '空字符串视为未设置' do
      described_class.with('') { expect(described_class.current).to be_nil }
    end
  end

  describe '.clear' do
    it '清除已设置的 Key' do
      described_class.current = 'sk-x'
      described_class.clear
      expect(described_class.current).to be_nil
    end
  end

  describe '.resolve' do
    it '显式传入的 Key 优先级最高' do
      described_class.with('sk-request-level') do
        expect(described_class.resolve(explicit: 'sk-explicit')).to eq('sk-explicit')
      end
    end

    it '其次使用请求级（临时覆盖）的 Key' do
      described_class.with('sk-request-level') do
        expect(described_class.resolve).to eq('sk-request-level')
      end
    end

    it '两者都没有时回落到配置文件里的 Key' do
      allow(QingxunConfig).to receive(:llm_api_key).and_return('sk-config')
      expect(described_class.resolve).to eq('sk-config')
      expect(described_class.resolve_with_source[:source]).to eq(:config)
    end

    it '请求级 Key 优先于配置文件' do
      allow(QingxunConfig).to receive(:llm_api_key).and_return('sk-config')
      described_class.with('sk-request-level') do
        expect(described_class.resolve).to eq('sk-request-level')
      end
    end

    it '完全没有 Key 时抛出 MissingApiKeyError' do
      allow(QingxunConfig).to receive(:llm_api_key).and_return(nil)
      expect { described_class.resolve }.to raise_error(described_class::MissingApiKeyError)
    end

    # 配置示例里就是 your_api_key_here，把它当有效 Key 会让"缺少 Key"永远不触发，
    # 问题被推迟成难懂的上游 401
    it '占位符不算已配置，仍抛出 MissingApiKeyError' do
      %w[your_api_key_here YOUR_API_KEY sk-xxxxxxxxxx changeme placeholder].each do |placeholder|
        allow(QingxunConfig).to receive(:llm_api_key).and_return(placeholder)
        expect { described_class.resolve }
          .to raise_error(described_class::MissingApiKeyError),
              "占位符 #{placeholder.inspect} 被误当成有效 Key"
      end
    end

    it '空字符串与纯空白不算已配置' do
      ['', '   '].each do |blank|
        allow(QingxunConfig).to receive(:llm_api_key).and_return(blank)
        expect { described_class.resolve }.to raise_error(described_class::MissingApiKeyError)
      end
    end
  end

  # 线程局部变量不得跨线程共享——这也是后台任务拿不到临时 Key 的根本原因
  describe '线程隔离' do
    it '一个线程设置的 Key 不会被另一个线程看到' do
      described_class.current = 'sk-main-thread'

      seen_in_other_thread = Thread.new { described_class.current }.value

      expect(seen_in_other_thread).to be_nil
      expect(described_class.current).to eq('sk-main-thread')
    end
  end
end
