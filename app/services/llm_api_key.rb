# frozen_string_literal: true

# LLM API Key 的请求级载体（开源版）
#
# 业务逻辑：
#   Key 只在配置文件 config/qingxun.yml 中维护（见 QingxunConfig）。为支持
#   "一次请求临时换 Key" 的场景，仍允许请求头显式携带 X-LLM-Api-Key 覆盖配置值。
#   无论哪种来源，Key 都**绝不**被持久化：不写库、不写日志、不进 job 参数。
#
# 隐性知识：
#   1. 线程局部变量**不跨线程传递**。后台任务跑在另一个线程里同样取不到 Key——
#      这是刻意的：把 Key 放进 job 参数，一旦队列换成会落库的适配器就会永久留存。
#      需要 Key 的 LLM 调用都必须在请求线程内完成。
#   2. 禁止写入 Rails.cache / session / cookie：多进程部署下不是可靠通道，
#      且过期前仍是一份可被读到的副本。
#   3. 用 around_action 而非 after_action 清除：after_action 在异常时不执行，
#      会把 Key 残留到同一线程的下一个请求里。
module LlmApiKey
  THREAD_KEY = :llm_api_key

  # 既没有请求 Key 也没有配置 Key 时抛出
  #
  # 隐性知识（重要，别改成 StandardError）：
  #   刻意继承 **Exception**。原因是「缺少 Key」是**配置问题**，重试不会变出 Key 来；
  #   而项目里各服务普遍用宽泛的 `rescue => e` 把异常包成返回值并重试，会被它吞掉。
  #   继承 Exception 让它穿透到底，由控制器 rescue_from 翻译成 400 + missing_llm_api_key。
  class MissingApiKeyError < Exception; end

  # 占位符不算已配置
  PLACEHOLDER_API_KEY = /\A(your[_-]?api[_-]?key.*|sk-?x{3,}|change[_-]?me|todo|placeholder)\z/i

  class << self
    # 当前请求携带的临时 Key（可能为 nil）
    def current
      Thread.current[THREAD_KEY]
    end

    def current=(value)
      Thread.current[THREAD_KEY] = value.presence
    end

    def clear
      Thread.current[THREAD_KEY] = nil
    end

    # 配置文件里的 Key；空值与占位符一律视为未配置
    def config_api_key
      value = QingxunConfig.llm_api_key.to_s.strip
      return nil if value.empty?
      return nil if value.match?(PLACEHOLDER_API_KEY)

      value
    end

    # 在指定 Key 的作用域内执行块；无论是否异常都必定恢复原值
    def with(key)
      previous = current
      self.current = key
      yield
    ensure
      self.current = previous
    end

    # 解析本次请求实际使用的 Key，并标明来源
    #
    # 顺序：显式传入 → 请求级（请求头）→ 配置文件
    #
    # 返回: { key: String, source: :explicit | :request | :config }
    def resolve_with_source(explicit: nil)
      return { key: explicit, source: :explicit } if explicit.present?
      return { key: current, source: :request } if current.present?

      config = config_api_key
      return { key: config, source: :config } if config

      raise MissingApiKeyError,
            '缺少 LLM API Key：请在 config/qingxun.yml 中配置 llm.api_key'
    end

    # 只要 Key，不关心来源
    def resolve(explicit: nil)
      resolve_with_source(explicit: explicit)[:key]
    end
  end
end
