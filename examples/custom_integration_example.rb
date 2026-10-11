# frozen_string_literal: true

# 自定义集成使用示例

class CustomIntegrationExample < NetCat::DeviceScript
  uses_integration :custom

  def run(connection)
    log_info "开始执行自定义集成示例"

    # 调用自定义函数
    result = custom.send_alarm(
      cpu: 90,
      host: "router-01",
      message: "CPU利用率过高"
    )

    log_info "调用结果: #{result}"

    record_check "自定义集成调用", result["success"],
      description: "测试自定义集成函数调用",
      expected: "返回 success: true",
      reason: result["success"] ? nil : "调用失败",
      suggestion: result["success"] ? nil : "检查自定义集成配置"

    build_script_result
  end
end
