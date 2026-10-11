# frozen_string_literal: true

# IntegrationCodeBuilder - 安全地组装自定义集成类代码
module IntegrationCodeBuilder
  class << self
    def build_and_validate(functions)
      valid_functions = functions.select { |f| f['name'] && !f['name'].empty? }

      if valid_functions.empty?
        return { success: true, code: empty_class_code }
      end

      code = build_code(valid_functions)
      syntax_errors = validate_syntax(code)

      unless syntax_errors.empty?
        return { success: false, errors: ["生成的代码语法错误: #{syntax_errors.join('; ')}"] }
      end

      { success: true, code: code }
    end

    def build_code(functions)
      valid_functions = functions.select { |f| f['name'] && !f['name'].empty? }

      if valid_functions.empty?
        return empty_class_code
      end

      # 逐行构建，确保每行缩进正确
      lines = []

      # 头部
      lines << "# frozen_string_literal: true"
      lines << ""
      lines << "# 自动生成的自定义集成类"
      lines << "# 可自定义对接您的系统"
      lines << ""
      lines << "module Qingxun"
      lines << "  module Integrations"
      lines << "    class GeneratedCustom < Base"
      lines << ""

      # 方法
      valid_functions.each do |func|
        name = func['name']
        mock_response = func['mock_response'] || '{}'

        lines << "      # 用户配置的函数: #{name}"
        lines << "      # 参数示例: #{func['param_example']}"
        lines << "      def #{name}(params)"
        lines << "        begin"
        lines << "          # 预定义的 模拟 响应"
        lines << "          #{generate_return_statement(mock_response)}"
        lines << "        rescue JSON::ParserError => e"
        lines << "          { \"error\" => \"模拟 响应 JSON 格式错误\", \"details\" => e.message }"
        lines << "        end"
        lines << "      end"
        lines << ""
      end

      # 尾部
      lines << "    end"
      lines << "  end"
      lines << "end"

      code = lines.join("\n")

      # 调试日志
      Rails.logger.debug "[IntegrationCodeBuilder] 生成的代码:\n#{code}"

      code
    end

    private

    def empty_class_code
      "# frozen_string_literal: true\n\nmodule Qingxun\n  module Integrations\n    class GeneratedCustom < Base\n      # 无自定义函数\n    end\n  end\nend"
    end

    # 生成安全的返回语句（返回 Ruby 对象字面量）
    def generate_return_statement(json_string)
      begin
        # 解析 JSON
        parsed = JSON.parse(json_string)

        # 转换为 Ruby 代码表示
        value_to_ruby(parsed)
      rescue JSON::ParserError => e
        # JSON 解析失败（防御性编程，控制器应该已经验证过）
        # 返回安全的默认值
        "{}"
      end
    end

    # 将值转换为 Ruby 代码表示
    def value_to_ruby(value)
      case value
      when Hash
        # Hash: {"key" => "value"}
        begin
          pairs = value.map do |k, v|
            "#{string_to_ruby(k)} => #{value_to_ruby(v)}"
          end
          "{#{pairs.join(', ')}}"
        rescue => e
          Rails.logger.error "[IntegrationCodeBuilder] value_to_ruby Hash 失败: #{e.message}"
          "{}"
        end
      when Array
        # Array: ["item1", "item2"]
        begin
          items = value.map { |v| value_to_ruby(v) }
          "[#{items.join(', ')}]"
        rescue => e
          Rails.logger.error "[IntegrationCodeBuilder] value_to_ruby Array 失败: #{e.message}"
          "[]"
        end
      when String
        string_to_ruby(value)
      when Numeric
        value.to_s
      when true
        "true"
      when false
        "false"
      when nil
        "nil"
      else
        # 其他类型使用 inspect
        begin
          value.inspect
        rescue => e
          Rails.logger.error "[IntegrationCodeBuilder] value_to_ruby 其他类型失败: #{e.message}"
          "nil"
        end
      end
    end

    # 将字符串转换为安全的 Ruby 字符串字面量
    def string_to_ruby(str)
      # 使用 Ruby 的 inspect 方法生成安全的字符串字面量
      # inspect 已经处理了所有必要的转义，包括引号、换行符、Unicode 等
      begin
        str.inspect
      rescue => e
        # 如果 inspect 失败（例如无效的编码），返回安全的默认值
        Rails.logger.error "[IntegrationCodeBuilder] string_to_ruby 失败: #{e.message}, str: #{str.force_encoding('UTF-8').inspect rescue 'ERROR'}"
        "\"ERROR\""
      end
    end

    def validate_syntax(code)
      errors = []

      begin
        RubyVM::InstructionSequence.compile(code)
      rescue SyntaxError => e
        errors << "语法错误: #{e.message}"
        Rails.logger.error "[IntegrationCodeBuilder] 语法错误: #{e.message}"
        Rails.logger.error "[IntegrationCodeBuilder] 生成的代码（前200字符）: #{code[0..200]}"
      rescue => e
        errors << "语法错误: #{e.message}"
      end

      errors
    end
  end
end
