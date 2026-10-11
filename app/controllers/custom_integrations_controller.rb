# frozen_string_literal: true

class CustomIntegrationsController < ApplicationController

  def show
    @integration = CustomIntegration.for_user(current_user)
    # 生成示例代码
    valid_functions = @integration.functions.select { |f| f['name'].present? }
    @generated_example_code = if valid_functions.empty?
      "# 无自定义函数"
    else
      IntegrationCodeBuilder.build_code(valid_functions)
    end

    respond_to do |format|
      format.html
      format.json { render json: integration_json(@integration, @generated_example_code) }
    end
  end

  def update
    @integration = CustomIntegration.for_user(current_user)
    functions = extract_functions_from_params

    # 阶段1：基本验证
    validation_errors = perform_basic_validation(functions)
    unless validation_errors.empty?
      return render_validation_failure(validation_errors)
    end

    # 阶段2：过滤有效函数
    valid_functions = functions.select { |f| f['name'].present? }

    # 阶段3：代码生成验证
    build_result = IntegrationCodeBuilder.build_and_validate(valid_functions)
    unless build_result[:success]
      return render_validation_failure(build_result[:errors])
    end

    # 阶段4：保存（只有前三个阶段都通过才执行）；保存前记一份历史快照
    @integration.functions = valid_functions
    @integration.generated_code = build_result[:code]
    @integration.record_history!(notes: params[:notes])

    if @integration.save
      # 清除缓存，确保脚本立即使用新配置
      Qingxun::Integrations::Custom.clear_cache!
      render_success
    else
      render_save_failure(@integration.errors)
    end
  end

  private

  # 页面/接口数据
  def integration_json(integration, example_code)
    {
      functions: integration.functions,
      generated_code: integration.generated_code,
      example_code: example_code,
      version_hash: integration.version_hash,
      updated_at: integration.updated_at&.iso8601,
      history: Array(integration.history)
    }
  end

  # 安全地从参数中提取函数数组
  def extract_functions_from_params
    functions_param = params[:functions]

    # 如果参数不存在或为空，返回空数组
    return [] if functions_param.blank?

    # 数组形态（Vue 页面直接提交数组）：逐项转为普通 Hash
    if functions_param.is_a?(Array)
      return functions_param.map do |f|
        if f.respond_to?(:to_unsafe_h) then f.to_unsafe_h
        elsif f.respond_to?(:to_h) then f.to_h
        else f
        end
      end
    end

    # 处理 ActionController::Parameters 对象
    if functions_param.is_a?(ActionController::Parameters)
      # 转换为不安全的哈希以获取原始数据
      functions_param = functions_param.to_unsafe_h
    end

    # 尝试转换为哈希并获取值
    if functions_param.respond_to?(:to_h)
      functions_hash = functions_param.to_h
      # 确保我们得到一个 Hash，然后获取值
      functions_hash.is_a?(Hash) ? functions_hash.values : []
    elsif functions_param.respond_to?(:to_a)
      functions_param.to_a
    else
      []  # 无法识别的格式，返回空数组
    end
  end

  # 执行基本验证，返回错误数组
  def perform_basic_validation(functions)
    errors = []

    functions.each_with_index do |func, index|
      name = func['name']
      param_example = func['param_example']
      mock_response = func['mock_response']

      # 1. 函数名不能为空
      if name.nil? || name.to_s.strip.empty?
        errors << "函数 #{index + 1} 的函数名不能为空"
        next  # 跳过该函数的后续验证
      end

      # 2. 函数名格式检查（小写字母、数字、下划线，必须以字母开头）
      unless name.match?(/\A[a-z][a-z0-9_]*\z/)
        errors << "函数名 '#{name}' 格式不正确，只能包含小写字母、数字和下划线，且必须以字母开头"
      end

      # 3. 参数示例不能为空
      if param_example.nil? || param_example.to_s.strip.empty?
        errors << "函数 '#{name}' 的参数示例不能为空"
      end

      # 4. Mock 响应不能为空
      if mock_response.nil? || mock_response.to_s.strip.empty?
        errors << "函数 '#{name}' 的 Mock 响应不能为空"
      end

      # 5. 参数示例必须是有效的 JSON
      if param_example && !param_example.to_s.strip.empty?
        begin
          parsed = JSON.parse(param_example)
          errors << "函数 '#{name}' 的参数示例应该是 JSON 对象" unless parsed.is_a?(Hash)
        rescue JSON::ParserError => e
          errors << "函数 '#{name}' 的参数示例 JSON 格式错误: #{e.message}"
        end
      end

      # 6. 模拟 响应必须是有效的 JSON
      if mock_response && !mock_response.to_s.strip.empty?
        begin
          parsed = JSON.parse(mock_response)
          errors << "函数 '#{name}' 的 模拟 响应应该是 JSON 对象" unless parsed.is_a?(Hash)
        rescue JSON::ParserError => e
          errors << "函数 '#{name}' 的 模拟 响应 JSON 格式错误: #{e.message}"
        end
      end
    end

    # 7. 检查函数名重复（基于非空函数名）
    function_names = functions.map { |f| f['name'] }.select(&:present?)
    if function_names.size != function_names.uniq.size
      function_names.group_by(&:itself).each do |name, occurrences|
        if occurrences.size > 1
          errors << "函数名 '#{name}' 重复了 #{occurrences.size} 次"
        end
      end
    end

    errors
  end

  # 渲染验证失败响应
  def render_validation_failure(errors)
    respond_to do |format|
      format.html do
        flash.now[:alert] = errors.join('; ')
        render :show
      end
      format.json { render json: { success: false, errors: errors }, status: :unprocessable_entity }
    end
  end

  # 渲染成功响应
  def render_success
    respond_to do |format|
      format.html { redirect_to custom_integration_path, notice: "集成已更新" }
      format.json { render json: { success: true, version_hash: @integration.version_hash } }
    end
  end

  # 渲染保存失败响应（数据库层面错误）
  def render_save_failure(active_record_errors)
    # 将 ActiveRecord 错误转换为字符串数组
    error_messages = active_record_errors.full_messages

    respond_to do |format|
      format.html do
        flash.now[:alert] = error_messages.join('; ')
        render :show
      end
      format.json { render json: { success: false, errors: error_messages }, status: :unprocessable_entity }
    end
  end
end
