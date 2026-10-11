# frozen_string_literal: true

require 'yaml'
require 'erb'

# 读取业务配置 config/qingxun.yml（见 config/qingxun.yml.example）。
#
# 开源版的 LLM Key、端点、模型与执行参数都集中在这个文件里维护。
# 文件不存在时全部回落到默认值，保证空部署也能启动（只是没有 Key，无法调用大模型）。
module QingxunConfig
  DEFAULT_LLM_API_URL = 'https://api.deepseek.com/v1/chat/completions'
  DEFAULT_LLM_MODEL   = 'deepseek-chat'

  class << self
    # 当前环境的配置哈希（symbol 键）。带缓存，进程内只读一次。
    def data
      @data ||= load_data
    end

    # 测试用：清缓存
    def reload!
      @data = nil
    end

    def llm
      data[:llm] || {}
    end

    def llm_api_key
      llm[:api_key].to_s.strip.presence || ENV['QINGXUN_LLM_API_KEY'].to_s.strip.presence
    end

    def llm_api_url
      llm[:api_url].to_s.strip.presence ||
        ENV['QINGXUN_LLM_API_URL'].to_s.strip.presence ||
        DEFAULT_LLM_API_URL
    end

    def llm_model
      llm[:model].to_s.strip.presence ||
        ENV['QINGXUN_LLM_MODEL'].to_s.strip.presence ||
        DEFAULT_LLM_MODEL
    end

    def execution
      data[:execution] || {}
    end

    private

    def load_data
      path = Rails.root.join('config', 'qingxun.yml')
      return {} unless File.exist?(path)

      raw = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true, permitted_classes: [Symbol]) || {}
      section = raw[Rails.env] || raw['default'] || {}
      section.deep_symbolize_keys
    rescue StandardError => e
      Rails.logger.warn("[QingxunConfig] 读取 config/qingxun.yml 失败：#{e.class}: #{e.message}")
      {}
    end
  end
end
