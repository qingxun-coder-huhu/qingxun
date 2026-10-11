# 自定义集成函数AI指导文档

## 📋 概述

自定义集成功能允许用户在脚本中调用自己定义的外部函数。当AI生成脚本时，如果用户已定义自定义函数，AI应该将这些函数整合到生成的脚本中，实现更复杂的业务逻辑。

## 🏗️ 核心机制

### 1. 用户定义
用户在自定义集成页面定义函数，包括：
- **函数名**：如 `send_alarm`
- **参数示例**：JSON格式，如 `{"cpu": 90, "host": "router-01"}`
- **Mock响应**：JSON格式，函数调用时返回的数据，如 `{"success" => true, "message" => "告警已发送"}`

### 2. 系统生成
系统自动生成对应的Ruby类：
```ruby
module Qingxun
  module Integrations
    class GeneratedCustom < Base
      def send_alarm(params)
        {"success" => true, "message" => "告警已发送"}
      end
    end
  end
end
```

### 3. 脚本使用
脚本通过以下方式使用自定义集成：
```ruby
class YourScript < Qingxun::DeviceScript
  uses_integration :custom  # 关键声明！

  def run(connection)
    # 调用自定义函数
    result = custom.send_alarm({cpu: 90, host: "router-01"})
    # 处理结果
  end
end
```

## 📝 AI生成脚本的指导原则

### 原则1：必须添加集成声明
**当脚本需要调用自定义函数时，必须在脚本类中添加 `uses_integration :custom` 声明。**

```ruby
# ✅ 正确
class CheckCpuUsage < Qingxun::DeviceScript
  uses_integration :custom

  def run(connection)
    # 可以调用 custom.xxx
  end
end

# ❌ 错误（缺少声明）
class CheckCpuUsage < Qingxun::DeviceScript
  def run(connection)
    # 这里调用 custom.xxx 会失败！
  end
end
```

### 原则2：检查用户是否定义了相关函数
**AI需要根据用户的描述判断是否需要使用自定义集成。**

- 如果用户描述中提到"发送告警"、"通知外部系统"、"调用API"等，且用户已定义相关函数，则使用自定义集成
- 如果用户没有自定义集成，或描述不涉及外部调用，则不需要添加集成声明

### 原则3：正确传递参数
**参数必须符合用户定义的参数示例格式。**

```ruby
# 用户定义的参数示例: {"cpu": 90, "host": "router-01"}

# ✅ 正确
result = custom.send_alarm({cpu: 85, host: "switch-01"})

# ✅ 正确（使用脚本中的变量）
cpu_value = parse_cpu(output)
result = custom.send_alarm({cpu: cpu_value, host: @device_config[:host]})

# ❌ 错误（参数格式不对）
result = custom.send_alarm(cpu: 85)  # 缺少花括号
result = custom.send_alarm("cpu=85") # 字符串格式不对
```

### 原则4：处理返回值
**自定义函数返回预设的Mock响应，通常是Hash格式。**

```ruby
result = custom.send_alarm({cpu: 90})
# result 可能是: {"success" => true, "message" => "告警已发送"}

# 检查调用结果
if result["success"]
  log_info("告警发送成功: #{result['message']}")
else
  log_error("告警发送失败: #{result['error']}")
end
```

## 🔧 整合模式

### 模式1：条件调用（最常见）
在满足特定条件时调用自定义函数。

```ruby
class MonitorCpu < Qingxun::DeviceScript
  uses_integration :custom

  def run(connection)
    # 获取CPU使用率
    output = connection.cli("show cpu usage")
    cpu_percent = parse_cpu(output)

    # 记录检查点
    record_check "CPU检查", cpu_percent <= 80,
      description: "检查CPU利用率",
      command: "show cpu usage",
      expected: "CPU ≤ 80%",
      reason: cpu_percent > 80 ? "CPU过高: #{cpu_percent}%" : nil

    # 条件调用自定义集成
    if cpu_percent > 80
      log_info("CPU超过阈值，发送告警")
      alarm_result = custom.send_alarm({
        cpu: cpu_percent,
        host: @device_config[:host],
        timestamp: Time.now.to_s
      })

      # 记录告警结果
      record_check "告警发送", alarm_result["success"],
        description: "通过自定义集成发送告警",
        expected: "返回 success: true",
        reason: alarm_result["success"] ? nil : "告警失败: #{alarm_result['error']}"
    end

    build_script_result
  end
end
```

### 模式2：数据上报
将解析的数据通过自定义集成上报到外部系统。

```ruby
class CollectDeviceInfo < Qingxun::DeviceScript
  uses_integration :custom

  def run(connection)
    # 收集设备信息
    version = get_version(connection)
    serial = get_serial(connection)

    # 通过自定义集成上报
    report_result = custom.report_device_info({
      host: @device_config[:host],
      version: version,
      serial_number: serial,
      collected_at: Time.now.iso8601
    })

    log_info("数据上报结果: #{report_result}")

    build_script_result
  end
end
```

### 模式3：多函数调用
调用多个自定义函数。

```ruby
class ComprehensiveCheck < Qingxun::DeviceScript
  uses_integration :custom

  def run(connection)
    # 检查1: CPU
    cpu = get_cpu_usage(connection)

    # 检查2: 内存
    memory = get_memory_usage(connection)

    # 调用不同自定义函数
    if cpu > 80
      custom.send_cpu_alarm({value: cpu})
    end

    if memory > 90
      custom.send_memory_alarm({value: memory})
    end

    # 发送汇总报告
    custom.send_daily_report({
      cpu: cpu,
      memory: memory,
      status: "completed"
    })

    build_script_result
  end
end
```

## 🚨 错误处理

### 1. 集成声明缺失
如果脚本中调用 `custom.xxx` 但没有 `uses_integration :custom`，会导致运行时错误：
```
undefined local variable or method `custom'
```

**解决方案**：确保在脚本类中添加声明。

### 2. 函数不存在
如果调用未定义的函数，会返回错误信息：
```ruby
result = custom.non_existent_function({})
# result => {"success"=>false, "error"=>"Method not found: non_existent_function"}
```

**解决方案**：只调用用户已定义的函数。

### 3. 参数格式错误
参数格式不符合用户定义的示例会导致Mock响应可能不符合预期。

**解决方案**：严格按照用户定义的参数示例格式传递参数。

## 📋 最佳实践

### 1. 声明位置
`uses_integration :custom` 应该紧跟在类定义之后：

```ruby
class YourScript < Qingxun::DeviceScript
  uses_integration :custom
  # 其他类级声明...

  def run(connection)
    # 方法实现
  end
end
```

### 2. 参数构建
使用明确的Hash构建参数：

```ruby
# ✅ 清晰
params = {
  value: parsed_value,
  host: @device_config[:host],
  timestamp: Time.now.iso8601,
  threshold: 80
}
result = custom.send_alarm(params)

# ❌ 混乱
result = custom.send_alarm(value: parsed_value, host: @device_config[:host])
```

### 3. 结果处理
始终检查并记录调用结果：

```ruby
result = custom.send_alarm(params)

if result["success"]
  log_info("调用成功: #{result['message']}")
  record_check "自定义集成调用", true,
    description: "调用自定义函数 #{function_name}",
    expected: "返回 success: true"
else
  log_error("调用失败: #{result['error']}")
  record_check "自定义集成调用", false,
    description: "调用自定义函数 #{function_name}",
    reason: result["error"]
end
```

### 4. 日志记录
在调用前后添加日志：

```ruby
log_info("准备调用自定义函数: send_alarm, 参数: #{params}")
result = custom.send_alarm(params)
log_info("调用结果: #{result}")
```

## 🧪 完整示例

### 示例1：CPU监控+告警
```ruby
class CpuMonitorWithAlarm < Qingxun::DeviceScript
  uses_integration :custom

  def run(connection)
    record_start!

    # 1. 获取CPU信息
    output = connection.cli("show cpu usage")
    log_info("设备返回CPU信息:\n#{output}")

    # 2. 解析CPU使用率
    cpu_percent = parse_cpu_percentage(output)
    log_info("解析到CPU使用率: #{cpu_percent}%")

    # 3. 记录检查点
    record_check "CPU利用率检查", cpu_percent <= 80,
      description: "检查设备CPU利用率是否超过阈值",
      command: "show cpu usage",
      expected: "CPU利用率 ≤ 80%",
      reason: cpu_percent > 80 ? "CPU过高: #{cpu_percent}%" : nil,
      suggestion: cpu_percent > 80 ? "检查异常进程" : nil

    # 4. 条件调用自定义集成
    if cpu_percent > 80
      log_info("CPU利用率 #{cpu_percent}% 超过阈值，发送告警")

      # 构建告警参数
      alarm_params = {
        cpu: cpu_percent,
        host: @device_config[:host],
        threshold: 80,
        timestamp: Time.now.iso8601,
        message: "设备CPU使用率超过阈值"
      }

      # 调用自定义集成
      alarm_result = custom.send_alarm(alarm_params)

      # 记录告警结果
      record_check "告警发送", alarm_result["success"],
        description: "通过自定义集成发送CPU告警",
        expected: "返回 success: true",
        reason: alarm_result["success"] ? nil : "告警发送失败: #{alarm_result['error']}",
        suggestion: alarm_result["success"] ? nil : "检查自定义集成配置"

      log_info("告警发送结果: #{alarm_result}")
    end

    build_script_result
  end

  private

  def parse_cpu_percentage(output)
    # 解析逻辑...
    if output =~ /CPU.*?(\d+(?:\.\d+)?)%/
      Regexp.last_match(1).to_f
    else
      0.0
    end
  end
end
```

### 示例2：设备信息收集+上报
```ruby
class DeviceInfoCollector < Qingxun::DeviceScript
  uses_integration :custom

  def run(connection)
    record_start!

    collected_data = {}

    # 1. 收集版本信息
    version_output = connection.cli("show version")
    version = parse_version(version_output)
    collected_data[:version] = version
    log_info("设备版本: #{version}")

    # 2. 收集序列号
    serial_output = connection.cli("show inventory")
    serial = parse_serial(serial_output)
    collected_data[:serial] = serial
    log_info("设备序列号: #{serial}")

    # 3. 记录检查点
    record_check "版本信息收集", version.present?,
      description: "收集设备版本信息",
      command: "show version"

    record_check "序列号收集", serial.present?,
      description: "收集设备序列号",
      command: "show inventory"

    # 4. 通过自定义集成上报数据
    if version.present? && serial.present?
      log_info("准备上报设备信息到外部系统")

      report_params = {
        device_info: collected_data,
        collection_time: Time.now.iso8601,
        collector: "qingxun_script"
      }

      report_result = custom.report_device_info(report_params)

      record_check "数据上报", report_result["success"],
        description: "上报设备信息到外部系统",
        expected: "返回 success: true",
        reason: report_result["success"] ? nil : "上报失败: #{report_result['error']}"

      log_info("数据上报结果: #{report_result}")
    end

    build_script_result
  end
end
```

## 🔄 工作流程总结

1. **判断需求**：分析用户描述，判断是否需要使用自定义集成
2. **检查函数**：确认用户是否定义了相关函数（通过系统提示词获取）
3. **添加声明**：在脚本类中添加 `uses_integration :custom`
4. **设计调用**：在合适的逻辑点调用自定义函数
5. **构建参数**：按照用户定义的参数示例格式构建参数Hash
6. **处理结果**：检查并记录函数调用结果
7. **错误处理**：添加适当的错误处理和日志记录

## 📚 相关参考

- `app/models/custom_integration.rb` - 自定义集成模型和提示词方法
- `lib/qingxun/integrations/custom.rb` - 自定义集成实现
- `lib/qingxun/device_script.rb` - `uses_integration` 方法定义
- `examples/custom_integration_example.rb` - 官方示例

通过遵循这些指导原则，AI可以生成正确使用自定义集成的脚本，实现更强大的自动化功能。

---
*文档生成时间: 2026-03-16*
*用途: 指导AI如何将自定义集成函数整合到生成的脚本中*