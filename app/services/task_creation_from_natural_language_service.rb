# frozen_string_literal: true

require_relative 'prompts'

# TaskCreationFromNaturalLanguageService —— 根据自然语言描述创建任务，智能匹配设备型号与适用脚本。
#
# 复用自线上版 net_cat/app/services/task_creation_from_natural_language_service.rb，
# 仅去掉云端专属的 UserRequest 请求记录（开源版不做用量/请求追踪），其余自检循环逻辑逐字保留。
#
# 业务逻辑：
#   1. 接收用户自然语言任务需求
#   2. 查询用户所有设备信息（id、名称、型号、描述）
#   3. 查询用户所有「调试完成」的脚本（id、名称、支持的设备型号、描述）
#   4. 调用配置里的 LLM，返回按设备型号分组的设备-脚本匹配结果
#   5. 结果交给 TaskInfoConverter 拍平成 devices/scripts 用于建任务
#
# 隐性知识：
#   - 设备型号可能包含中文逗号，需要正确处理
#   - 返回格式为按设备型号分组的 JSON 结构
#   - 自检循环：LLM 生成 → 另一个 LLM 自检 → 不通过则把意见并回需求重试（最多 5 轮）
class TaskCreationFromNaturalLanguageService
  MAX_SELF_CHECK = 5
  MAX_GENERATE_RETRY = 3

  def initialize(user, natural_language)
    @user = user
    @natural_language = natural_language.to_s.strip
    raise ArgumentError, '自然语言描述不能为空' if @natural_language.empty?
  end

  # 返回：{ success: true, data: { "型号" => { devs: [...], scripts: [...] } }, self_check_count: n }
  # 或：  { success: false, error: "错误信息", code: "..." }
  def call
    devices = fetch_user_devices
    scripts = fetch_user_scripts

    # 前置校验：缺设备、缺脚本、或脚本都还没调试完成时直接返回具体原因——不要进自检循环。
    # 隐性知识：交给大模型的脚本只有「调试完成」的（fetch_user_scripts 用 debugged 过滤），
    # 所以上面两种情况脚本列表都是空数组；否则会白跑 5 轮大模型调用（约十几秒 + token 成本），
    # 最后只回一句「自检达到最大次数 5 次仍未能通过」，用户完全不知道是自己还没有可用脚本。
    if (precheck = precheck_error(devices, scripts))
      return { success: false, error: precheck[:error], code: precheck[:code] }
    end

    original_requirement = @natural_language
    current_requirement = @natural_language
    self_check_count = 0
    verification_result = nil

    while self_check_count < MAX_SELF_CHECK
      begin
        # 1) 调 LLM 生成匹配结果（内层重试处理 JSON 格式问题）
        result = generate_with_retry(current_requirement, devices, scripts)

        # 2) 自检 LLM 输出
        verification_result = verify_llm_output(
          original_requirement: original_requirement,
          llm_output: result,
          devices: devices,
          scripts: scripts
        )

        # 3) 通过
        if verification_result['passed']
          return {
            success: true,
            data: result,
            self_check_passed: true,
            self_check_count: self_check_count + 1
          }
        end

        # 4) 不通过：把自检意见并回需求，重试
        self_check_count += 1
        Rails.logger.info("自检未通过 (#{self_check_count}/#{MAX_SELF_CHECK}): #{verification_result['reason']}")
        current_requirement = build_self_check_feedback_requirement(
          original_requirement: original_requirement,
          verification_result: verification_result,
          self_check_count: self_check_count
        )
      rescue StandardError => e
        self_check_count += 1
        Rails.logger.warn("创建任务失败，正在自检重试 (#{self_check_count}/#{MAX_SELF_CHECK}): #{e.message}")

        if self_check_count >= MAX_SELF_CHECK
          return {
            success: false,
            error: "创建任务失败，已自检 #{MAX_SELF_CHECK} 次。最后一次错误：#{e.message}",
            self_check_count: self_check_count
          }
        end

        current_requirement = build_error_feedback_requirement(
          original_requirement: original_requirement,
          error: e.message,
          self_check_count: self_check_count
        )
      end
    end

    # 达到最大自检次数：把最后一轮自检给出的具体原因带上
    error_message = self_check_failure_message(verification_result, MAX_SELF_CHECK)
    { success: false, error: error_message, code: 'self_check_failed', self_check_count: MAX_SELF_CHECK }
  end

  private

  # 自检前的必要前置校验。返回 nil 表示通过；否则返回 { error:, code: }。
  def precheck_error(devices, scripts)
    if devices.empty?
      return { error: '还没有设备：请先在「设备管理」添加设备后再创建任务', code: 'no_devices' }
    end

    return nil unless scripts.empty?

    total = @user.scripts.count
    if total.zero?
      {
        error: '还没有脚本：请先在脚本页创建脚本并完成调试（状态为「调试完成」）后再创建任务',
        code: 'no_scripts'
      }
    else
      {
        error: "当前共 #{total} 个脚本，但没有任何一个处于「调试完成」状态，无法用于生成任务；" \
               '请先在脚本页完成调试并标记为「调试完成」后再试',
        code: 'no_debugged_scripts'
      }
    end
  end

  # 自检跑满次数时的失败文案：带上最后一轮自检的具体原因（过长时截断，避免提示框被撑爆）
  def self_check_failure_message(verification_result, max_self_check)
    reason = verification_result && verification_result['reason'].to_s.strip
    return "自检 #{max_self_check} 次仍未能通过（自检未返回具体原因）" if reason.nil? || reason.empty?

    reason = "#{reason[0, 178]}…" if reason.length > 180
    "自检 #{max_self_check} 次未通过：#{reason}"
  end

  # 用户所有设备：[{ id:, name:, device_model:, description: }, ...]
  def fetch_user_devices
    @user.network_elements.select(:id, :name, :device_model, :description).map do |device|
      {
        id: device.id,
        name: device.name,
        device_model: device.device_model,
        description: device.description
      }
    end
  end

  # 用户所有「调试完成」的脚本：[{ id:, name:, device_models: [...], description: }, ...]
  def fetch_user_scripts
    @user.scripts.debugged.select(:id, :name, :device_models, :description).map do |script|
      {
        id: script.id,
        name: script.name,
        device_models: script.device_models || [],
        description: script.description
      }
    end
  end

  def call_llm_api(prompt)
    LlmRequestService.call(
      messages: [
        { role: 'system', content: Prompts::TaskCreation.system_prompt },
        { role: 'user', content: prompt }
      ],
      service_name: 'TaskCreationFromNaturalLanguageService',
      step_name: 'generate'
    )
  end

  def call_verification_llm_api(prompt)
    LlmRequestService.call(
      messages: [
        { role: 'system', content: Prompts::TaskCreation::SelfVerification.system_prompt(
          devices: fetch_user_devices,
          scripts: fetch_user_scripts
        ) },
        { role: 'user', content: prompt }
      ],
      service_name: 'TaskCreationFromNaturalLanguageService',
      step_name: 'verify'
    )
  end

  def parse_response(api_response)
    content = api_response.dig('choices', 0, 'message', 'content')
    raise 'API 响应未包含内容' if content.nil?

    JSON.parse(extract_json(content))
  rescue JSON::ParserError => e
    raise "JSON 解析失败: #{e.message}, 原始内容: #{content}"
  end

  # 调 LLM 生成匹配结果（内层重试处理格式问题）
  def generate_with_retry(current_requirement, devices, scripts)
    retry_count = 0
    begin
      prompt = Prompts::TaskCreation.build(current_requirement, @natural_language, devices, scripts)
      parse_response(call_llm_api(prompt))
    rescue StandardError => e
      retry_count += 1
      Rails.logger.warn("生成匹配结果失败，正在重试 (#{retry_count}/#{MAX_GENERATE_RETRY}): #{e.message}")
      raise "生成匹配结果失败，已重试 #{MAX_GENERATE_RETRY} 次。最后一次错误：#{e.message}" if retry_count >= MAX_GENERATE_RETRY

      retry
    end
  end

  def verify_llm_output(original_requirement:, llm_output:, devices:, scripts:)
    prompt = Prompts::TaskCreation::SelfVerification.build(
      original_requirement: original_requirement,
      llm_output: llm_output,
      devices: devices,
      scripts: scripts
    )
    parse_verification_response(call_verification_llm_api(prompt))
  end

  def parse_verification_response(api_response)
    content = api_response.dig('choices', 0, 'message', 'content')
    raise '自检 API 响应未包含内容' if content.nil?

    JSON.parse(extract_json(content))
  rescue JSON::ParserError => e
    # 自检响应解析失败时按"未通过"处理，把原因带回去
    { 'passed' => false, 'reason' => "自检响应解析失败: #{e.message}", 'suggestions' => [], 'details' => {} }
  end

  def build_self_check_feedback_requirement(original_requirement:, verification_result:, self_check_count:)
    <<~FEEDBACK
      【第 #{self_check_count} 次自检未通过】

      【原始需求】
      #{original_requirement}

      【自检意见】
      问题：#{verification_result['reason']}

      建议修改：
      #{Array(verification_result['suggestions']).map { |s| "- #{s}" }.join("\n")}

      【请根据上述意见重新生成匹配结果】
    FEEDBACK
  end

  def build_error_feedback_requirement(original_requirement:, error:, self_check_count:)
    <<~FEEDBACK
      【第 #{self_check_count} 次自检重试】

      【原始需求】
      #{original_requirement}

      【上次错误】
      #{error}

      【请修复上述问题后重新生成匹配结果】
    FEEDBACK
  end

  # 从响应里提取 JSON（可能包在 ```json 代码块里）
  def extract_json(content)
    json_match = content.match(/```json\s*(.*?)\s*```/m)
    return json_match[1] if json_match

    json_match = content.match(/```\s*(.*?)\s*```/m)
    return json_match[1] if json_match

    content
  end
end
