# frozen_string_literal: true

# 任务完成处理器
# 单一职责：处理任务完成后的状态更新和清理
class TaskFinalizer
  def initialize(state_manager)
    @state_manager = state_manager
  end

  # 完成任务
  # @param execution [LocalTaskExecution] 执行记录对象
  def finalize(execution)
    final_state = @state_manager.get_task(execution.id)
    puts "[TaskFinalizer] Finalizing task, has final_state: #{!final_state.nil?}"

    if final_state
      # 任务状态只看"跑完了没有"，**不看每个网元/脚本的判定结果**。
      #
      # 隐性知识（用户报过）：原来这里拿「所有脚本都 completed」决定任务是否成功，于是
      # "巡检跑完了、但有一台网元失败"会把**整个任务**标成失败 —— 用户看任务列表会以为
      # "这个任务没跑成"，而其实它跑完了，结论是"那台设备有问题"。这是两件事，必须分开：
      #   · 任务/执行状态 = **流程**状态：所有执行单元都处理完就是 completed；
      #   · 网元与脚本状态 = **巡检结果**：失败/部分通过由它们自己表达（任务列表、网元详情、
      #     报告里的统计与逐条检查点都能看到）。
      # 真正没跑完的情况（状态丢失、取消、异常）仍然不是 completed。
      #
      # finalize 只在"所有执行单元都处理完"时才会被调用（见 task_execution_coordinator.rb
      # 的 finalize_if_complete），所以走到这里就说明跑完了。
      @state_manager.update_task(execution.id, {
        status: 'completed',
        progress: 100,
        completed_at: Time.now.iso8601
      })
      # 使用内存中的最终状态来完成任务
      execution.complete_from_memory!(final_state, success: true)
    else
      # 内存里已经没有最终状态（进程重启、状态丢失）：这才是任务级的失败
      execution.complete!(success: false)
    end

    puts "[TaskFinalizer] 任务执行完成: execution_id=#{execution.id}"
  end
end
