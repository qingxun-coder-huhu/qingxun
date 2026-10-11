# frozen_string_literal: true

require 'httparty'
require 'json'
require 'digest'
require 'securerandom'
require_relative 'generation_request_context'
require_relative 'prompts'

# ScriptGenerationService 负责调用 DeepSeek API，根据自然语言描述生成 Ruby 脚本代码。
#
# 业务逻辑：
#   - 用户输入自然语言描述，将命令-响应，处理逻辑发给大模型。
#   - 服务构造提示词，其中包含现有脚本示例和用户描述。
#   - 调用大模型api获取生成的代码。
#   - 从 API 响应中提取纯 Ruby 代码块。
#   - 将生成的代码保存到数据库。
#   - 返回代码供控制器使用。
#
# 隐性知识：
#   - DeepSeek API 端点、模型名称和 API 密钥通过环境变量配置。
#   - 生成的代码必须继承自 Qingxun::DeviceScript 并实现 run 方法。
#   - 提示词设计对生成质量至关重要，需要根据实际反馈迭代优化。
class ScriptGenerationService

  # 初始化服务。
  # 参数：
  #   description: 用户自然语言描述字符串
  #   feedback: 外部反馈信息，用于指导AI改进生成（可选）
  #   user: 当前用户（可选），用于获取自定义集成信息
  #   existing_code: 现有脚本代码（可选）。提供时进入"微调"模式：在该代码基础上做最小改动
  #   branches: 分支描述数组 [{name:, description:}]，微调模式下交给模型以适配分支改动
  #   script_uid: 脚本唯一标识（可选）。页面初始化时确定，作为生成类名的后缀；
  #               未提供时回退为随机 16 位十六进制
  def initialize(description, feedback: nil, user: nil, existing_code: nil, branches: [], script_uid: nil)
    @description = description.to_s.strip
    raise ArgumentError, '描述不能为空' if @description.empty?
    @feedback = feedback
    @user = user
    @existing_code = existing_code.to_s.strip
    @branches = Array(branches)
    @script_uid = script_uid.to_s.strip.presence
  end

  # 执行生成过程。
  # 返回哈希 { code: '生成的 Ruby 代码', command_mapping: '命令映射数据', description: '简短脚本描述', script_name: '脚本名称'}
  def call
    # 获取或创建用户请求记录（如果有关联用户）
    user_request = get_or_create_user_request
    if user_request
      # 设置当前请求上下文
      set_request_context(user_request.request_id)
      # 标记请求为处理中
      user_request.mark_processing!
    end

    max_retries = 3
    retry_count = 0
    error_history = ""

    while retry_count < max_retries
      begin
        prompt = if @existing_code.present?
                   Prompts::ScriptGeneration.build_refine(
                     existing_code: @existing_code,
                     mainline_description: @description,
                     branches: @branches,
                     error_history: error_history,
                     feedback: @feedback
                   )
                 else
                   Prompts::ScriptGeneration.build(error_history, @description, @feedback)
                 end

        response = call_deepseek_api(prompt)

        # 从响应中同时提取脚本、命令映射、脚本名称和描述
        script_content, mapping_content, script_name, description = extract_script_and_mapping(response)

        # 验证脚本语法
        validate_ruby_syntax(script_content)
        # 确保类名唯一性，避免类同名被覆盖
        script_content = ensure_unique_class_name(script_content)
        # 验证JSON格式并解析命令映射
        command_mapping = parse_command_mapping(mapping_content)

        # 不再保存文件到本地，直接返回生成的内容
        # 标记请求为完成（如果存在）
        if user_request
          result = {
            code_length: script_content.length,
            command_mapping_count: command_mapping.length,
            script_name: script_name,
            description_length: description.length
          }
          user_request.mark_completed!(result)
        end

        # 添加调试日志
        Rails.logger.error "[ERROR] ScriptGenerationService - 最终返回结果:"
        Rails.logger.error "[ERROR] ScriptGenerationService - code 长度: #{script_content.length}"
        Rails.logger.error "[ERROR] ScriptGenerationService - command_mapping 数量: #{command_mapping.length}"
        Rails.logger.error "[ERROR] ScriptGenerationService - script_name: #{script_name}"
        Rails.logger.error "[ERROR] ScriptGenerationService - description: #{description}"

        return { code: script_content, command_mapping: command_mapping, script_name: script_name, description: description }
      rescue LlmRequestService::MaxTokensReachedError => e
        # 如果是达到 max_tokens 限制，直接退出重试循环
        Rails.logger.error("API 响应达到 max_tokens 限制，停止重试: #{e.message}")
        # 标记请求为失败（如果存在）
        user_request.mark_failed!(e.message) if user_request
        raise e
      rescue => e
        retry_count += 1
        error_history = "第#{retry_count}次尝试失败：#{e.message}\n#{e.backtrace[0..5].join("\n")}"
        Rails.logger.warn("生成脚本和映射失败，正在重试 (#{retry_count}/#{max_retries}): #{e.message}")
        if retry_count >= max_retries
          # 标记请求为失败（如果存在）
          user_request.mark_failed!(e.message) if user_request
          raise "生成脚本和映射失败，已重试 #{max_retries} 次。最后一次错误：#{e.message}\n调用栈:\n#{e.backtrace.first(5).join("\n")}"
        end
      end
    end
  end

  private

  # 请求上下文（开源版不再落库记录，见 GenerationRequestContext）
  def get_or_create_user_request
    GenerationRequestContext.current
  end

  # 设置当前请求上下文
  def set_request_context(request_id)
    Thread.current[:user_request_context] ||= {}
    Thread.current[:user_request_context][:request_id] = request_id
  end

  # 从 API 响应中同时提取脚本、命令映射、脚本名称和简短描述。
  # 返回 [script_content, mapping_content, script_name, description]
  def extract_script_and_mapping(api_response)
    content = api_response.dig('choices', 0, 'message', 'content')
    raise 'API 响应未包含内容' if content.nil?

    # 添加调试日志
    Rails.logger.error "[ERROR] ScriptGenerationService - API 响应内容长度: #{content.length}"
    Rails.logger.error "[ERROR] ScriptGenerationService - API 响应内容前500字符: #{content[0..500]}"

    # 分割脚本、映射、脚本名称和描述部分：分别位于 ```ruby、```json、```script_name 和 ```description 代码块中。
    # 使用正则提取四个代码块
    ruby_match = content.match(/```ruby\s*(.*?)```/m)
    json_match = content.match(/```json\s*(.*?)```/m)
    name_match = content.match(/```script_name\s*(.*?)```/m)
    desc_match = content.match(/```description\s*(.*?)```/m)

    # 添加调试日志
    Rails.logger.error "[ERROR] ScriptGenerationService - ruby_match: #{ruby_match ? '找到' : '未找到'}"
    Rails.logger.error "[ERROR] ScriptGenerationService - json_match: #{json_match ? '找到' : '未找到'}"
    Rails.logger.error "[ERROR] ScriptGenerationService - name_match: #{name_match ? '找到' : '未找到'}"
    Rails.logger.error "[ERROR] ScriptGenerationService - desc_match: #{desc_match ? '找到' : '未找到'}"

    # 如果找不到代码块，尝试其他变体
    if ruby_match.nil? && json_match.nil?
      Rails.logger.error "[ERROR] ScriptGenerationService - 无法找到任何代码块，完整内容: #{content}"
      raise '无法从响应中提取脚本和映射内容'
    end

    # Ruby代码块是必需的
    if ruby_match.nil?
      Rails.logger.error "[ERROR] ScriptGenerationService - 找不到Ruby代码块，完整内容: #{content}"
      raise '无法从响应中提取Ruby脚本代码'
    end

    script_content = ruby_match[1].strip
    mapping_content = json_match ? json_match[1].strip : ''
    script_name = name_match ? name_match[1].strip : ''
    description = desc_match ? desc_match[1].strip : ''

    # 检查提取的内容是否为空
    if script_content.empty?
      Rails.logger.error "[ERROR] ScriptGenerationService - 提取的Ruby脚本内容为空！"
      Rails.logger.error "[ERROR] ScriptGenerationService - ruby_match[1] 原始内容: #{ruby_match[1].inspect}"
    end

    if mapping_content.empty? && json_match
      Rails.logger.error "[ERROR] ScriptGenerationService - 提取的映射内容为空（但找到了json代码块）"
      Rails.logger.error "[ERROR] ScriptGenerationService - json_match[1] 原始内容: #{json_match[1].inspect}"
    end

    # 添加调试日志
    Rails.logger.error "[ERROR] ScriptGenerationService - 提取的脚本内容长度: #{script_content.length}"
    Rails.logger.error "[ERROR] ScriptGenerationService - 提取的映射内容长度: #{mapping_content.length}"
    Rails.logger.error "[ERROR] ScriptGenerationService - 提取的脚本名称: #{script_name}"
    Rails.logger.error "[ERROR] ScriptGenerationService - 提取的描述: #{description}"

    script_content = clean_code_string(script_content)
    [script_content, mapping_content, script_name, description]
  end

  # 验证 Ruby 代码语法是否正确。
  def validate_ruby_syntax(code)
    # 使用 RubyVM::InstructionSequence.compile 检查语法
    RubyVM::InstructionSequence.compile(code)
  rescue SyntaxError => e
    raise "生成的 Ruby 代码存在语法错误: #{e.message}"
  end

  # 解析命令映射 JSON 内容。
  # 返回哈希数组 [{ command: '...', response: '...' }]
  def parse_command_mapping(mapping_content)
    CommandMappingParser.parse(mapping_content)
  rescue CommandMappingParser::ParseError => e
    raise e.message
  end

  # 调用 DeepSeek API。
  # 返回 API 响应（解析后的哈希）。
  def call_deepseek_api(prompt)
    # 获取用户自定义集成信息
    system_prompt = Prompts::ScriptGeneration.system_prompt
    if @user.present?
      custom_integration = @user.custom_integration
      if custom_integration.present? && custom_integration.functions.present?
        custom_prompt = CustomIntegration::PromptMethods.build_prompt(custom_integration)
        system_prompt += "\n\n#{custom_prompt}"
      end
    end

    LlmRequestService.call(
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: prompt }
      ],
      service_name: 'ScriptGenerationService',
      step_name: 'generate'
    )
  end

  # 清理 Ruby 代码字符串，移除 Markdown 代码块标记、纠正 require 错误等。
  # 参数 code_string: 可能包含 ```ruby 标记的原始代码字符串。
  # 返回清理后的纯 Ruby 代码。
  def clean_code_string(code_string)
    return '' if code_string.nil?
    content = code_string.dup
    # 移除可能的 Markdown 代码块标记（开头和结尾）
    content.gsub!(/\A```ruby\s*/, '')
    content.gsub!(/```\s*\z/, '')

    # 按行分割，过滤掉所有包含 ``` 的行（无论位置）
    lines = content.lines
    lines.reject! { |line| line.include?('```') }

    # 压缩连续空行：仅保留一个空行
    compressed_lines = []
    lines.each do |line|
      # 如果当前行是空行（仅空白字符）且上一条也是空行，则跳过
      if line.strip.empty?
        compressed_lines << line unless compressed_lines.last&.strip&.empty?
      else
        compressed_lines << line
      end
    end

    content = compressed_lines.join

    # 纠正常见的 require 错误：模型有时会写 netcat / net_cat（旧品牌），
    # 统一归一到当前框架的 require 'qingxun'
    content.gsub!(/require\s+['"]net_?cat['"]/, "require 'qingxun'")
    content.gsub!(/require\s+['"]qingxun_script['"]/, "require 'qingxun'")

    content.strip
  end

  # 确保生成的脚本类名唯一：在类名后追加 script_uid（16 位十六进制）。
  #
  # 隐性知识：
  #   1. 后缀来自页面初始化时确定的 script_uid，而不是每次生成都随机——同一脚本在重试
  #      与微调之间类名保持稳定；不同脚本仍全局唯一，避免 load_script 常量重开
  #      （stale method）与 tmp/debug_scripts/<类名>.rb 同名冲突。
  #   2. 必须幂等：微调时模型会沿用旧代码里已经带后缀的类名，若再追加就会变成
  #      Foo_uid_uid。因此已以 "_#{suffix}" 结尾时原样返回。
  def ensure_unique_class_name(code)
    # 匹配类定义模式，支持模块内的类定义
    # 匹配：module QingxunScript 后跟类定义，或者直接类定义
    # 使用多行模式匹配，处理可能的缩进
    pattern = /(module\s+QingxunScript\s*(?:.*?\n)*?\s*)?class\s+(\w+)\s*<\s*Qingxun::DeviceScript/m
    match = pattern.match(code)
    raise "解析类名出错" unless match

    module_prefix = match[1] || ''
    original_class_name = match[2]

    # 页面初始化时确定的标识；调用方未提供时回退为随机 16 位十六进制
    suffix = @script_uid || SecureRandom.hex(8)
    # 幂等：已经带同一个后缀（例如微调沿用旧类名）就不再追加
    return code if original_class_name.end_with?("_#{suffix}")

    new_class_name = "#{original_class_name}_#{suffix}"

    # 构建替换模式，保持原有的模块前缀
    # 如果有关键字 module QingxunScript，则保持它
    if module_prefix&.include?('module QingxunScript')
      # 保持模块前缀不变，只替换类名
      replacement = "#{module_prefix.chomp}class #{new_class_name} < Qingxun::DeviceScript"
    else
      # 没有模块前缀，直接替换类名
      replacement = "class #{new_class_name} < Qingxun::DeviceScript"
    end

    # 替换类名定义
    code.gsub!(pattern, replacement)

    # 同时替换类名在文件中的其他出现？通常不需要，因为类名仅在定义和使用时出现。
    # 返回修改后的代码
    code
  end

end
