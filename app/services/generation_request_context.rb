# frozen_string_literal: true

# 生成请求的轻量上下文（开源版）
#
# 线上版用 UserRequest 记录每次生成请求的生命周期（pending/processing/completed/failed），
# 供管理后台查询与统计。开源版没有后台与遥测需求，这里用一个**不落库**的对象替代：
# 它只承载 request_id —— 作用是把一次请求内的多次 LLM 调用归到同一个会话日志目录
# （见 LlmSessionLogger），状态标记方法都是空实现。
class GenerationRequestContext
  attr_reader :request_id

  def initialize(request_id = nil)
    @request_id = (request_id.presence || SecureRandom.uuid)
  end

  # 幂等地取得当前线程的上下文（复用中间件写入的 request_id）
  def self.current
    ctx = Thread.current[:user_request_context]
    new(ctx && ctx[:request_id])
  end

  def mark_processing!; end
  def mark_completed!(_result = nil); end
  def mark_failed!(_message = nil); end
end
