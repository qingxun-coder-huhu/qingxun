# frozen_string_literal: true

# 设备执行处理器
# 单一职责：处理单个设备上的完整执行流程（登录+执行所有脚本）
class DeviceExecutionProcessor
  def initialize(state_manager, login_handler, script_executor)
    @state_manager = state_manager
    @login_handler = login_handler
    @script_executor = script_executor
  end

  # 处理单个设备的执行
  # @param execution_id [String] 执行记录ID
  # @param device_id [String] 设备ID
  # @param device_unit [Hash] 设备执行单元
  # @param execution [LocalTaskExecution] 执行记录对象
  def process(execution_id, device_id, device_unit, execution)
    device_name = device_unit['name'] || device_unit[:name] || device_id
    connection_info = device_unit['connection_info'] || device_unit[:connection_info] || {}
    scripts = device_unit['scripts'] || device_unit[:scripts] || {}
    login_log_path = device_unit['login_log_path'] || device_unit[:login_log_path]
    
    puts "[DeviceExecutionProcessor] 开始处理设备: #{device_name} (#{device_id})"
    puts "[DeviceExecutionProcessor] 登录日志路径: #{login_log_path}" if login_log_path

    device = nil
    begin
      device = @login_handler.login(connection_info, log_file_path: login_log_path)
      puts "[DeviceExecutionProcessor] 设备登录成功: #{device_name}"
    rescue => e
      puts "[DeviceExecutionProcessor] 设备登录失败: #{device_name}, 错误: #{e.message}"
      # 设备级状态："登录不上"就是这台设备没跑成（界面显示"登录失败"）。
      # 脚本的判定结果不代表设备状态，两件事分开表达。
      update_device_status(execution_id, device_id, 'failed', execution,
                           error: "设备登录失败: #{e.message}")
      mark_all_scripts_failed(execution_id, device_id, scripts, execution, e.message)
      return
    end

    update_device_status(execution_id, device_id, 'running', execution)

    begin
      scripts.each do |script_id, script_info|
        process_single_script(execution_id, device_id, script_id, script_info, device, execution)
      end
    ensure
      @login_handler.close(device)
      puts "[DeviceExecutionProcessor] 设备连接已关闭: #{device_name}"
    end

    # 登录成功、脚本都尝试过了 —— 无论脚本判定如何，这台设备的流程都算完成
    # （界面显示"执行完成"）。脚本级失败/部分通过在检查点结论里表达。
    update_device_status(execution_id, device_id, 'completed', execution)
  end

  private

  # 处理单个脚本
  def process_single_script(execution_id, device_id, script_id, script_info, device, execution)
    script_name = script_info['name'] || script_info[:name] || script_id
    
    puts "[DeviceExecutionProcessor] 开始执行脚本: #{script_name}"

    # 更新状态为运行中
    update_script_status(execution_id, device_id, script_id, 'running', execution)

    # 执行脚本
    result = @script_executor.execute(device, script_info)

    # 更新状态为完成
    # 脚本状态跟结论走（四态）：success→completed（成功）、partial→partial（部分通过）、
    # failure→failed（有检查点但一个都没过）、error→error（执行异常 / 找不到脚本类）
    status = case result[:conclusion]
             when 'success' then 'completed'
             when 'partial' then 'partial'
             when 'error' then 'error'
             else 'failed'
             end
    update_script_status(
      execution_id, device_id, script_id, status, execution,
      conclusion: result[:conclusion],
      output: result[:output][0..10000],
      error: result[:error],
      checkpoints: result[:checkpoints]
    )

    puts "[DeviceExecutionProcessor] 脚本执行完成: #{script_name}, 状态: #{status}"
  end

  # 更新设备级状态（同时更新内存与文件；数据库在任务结束时统一落）
  def update_device_status(execution_id, device_id, status, execution, **options)
    @state_manager.update_device_status(execution_id, device_id, status, **options)
    execution.update_device_status!(device_id, status, **options) if execution.respond_to?(:update_device_status!)
  end

  # 标记所有脚本为失败
  def mark_all_scripts_failed(execution_id, device_id, scripts, execution, error_message)
    scripts.each_key do |script_id|
      update_script_status(
        execution_id, device_id, script_id, 'failed', execution,
        error: "设备登录失败: #{error_message}"
      )
    end
  end

  # 更新脚本状态（同时更新内存和文件）
  def update_script_status(execution_id, device_id, script_id, status, execution, **options)
    @state_manager.update_script_status(execution_id, device_id, script_id, status, **options)
    execution.update_script_status!(device_id, script_id, status, **options)
  end
end
