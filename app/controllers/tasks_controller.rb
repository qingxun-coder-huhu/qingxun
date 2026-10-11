# frozen_string_literal: true

require_relative '../services/task_runner'

# 任务管理（开源版）
#
# 任务 = 若干「设备 × 脚本」的组合。职责：
#   - 列表 / 详情 / 新建 / 编辑 / 删除；
#   - 「运行」：交给 TaskRunner 后台并发下发到真机，前端轮询 /status 原地更新；
#   - 报告页数据与导出。
# 页面（列表、编辑、详情、报告）为 Vue 3 + Element Plus，接口提供 JSON。
class TasksController < ApplicationController
  before_action :set_task, only: [:show, :run, :destroy, :status, :update, :reset,
                                  :report, :report_data, :export_report, :edit, :edit_data]

  # GET /tasks
  def index
    @tasks = current_user.tasks.order(created_at: :desc)
    respond_to do |format|
      format.html
      format.json { render json: @tasks.map { |t| task_json(t) } }
    end
  end

  # GET /tasks/:id
  def show
    @executions = @task.task_executions.includes(:script, :network_element).ordered
  end

  # GET /tasks/:id/edit
  def edit; end

  # GET /tasks/:id/edit_data
  def edit_data
    render json: {
      task: { id: @task.id, name: @task.name, description: @task.description },
      devices: devices_pool,
      scripts: scripts_pool,
      selected_device_ids: @task.network_elements.pluck(:id),
      selected_script_ids: @task.scripts.pluck(:id)
    }
  end

  # GET /tasks/new
  def new
    @task = current_user.tasks.new
  end

  # GET /tasks/new_data —— 新建任务页的选择池（与编辑页结构一致）
  def new_data
    render json: {
      task: { id: nil, name: '', description: '' },
      devices: devices_pool,
      scripts: scripts_pool,
      selected_device_ids: [],
      selected_script_ids: []
    }
  end

  # POST /tasks
  def create
    @task = current_user.tasks.new(name: task_params[:name], description: task_params[:description])
    script_ids = Array(params[:script_ids]).reject(&:blank?)
    device_ids = Array(params[:device_ids]).reject(&:blank?)

    if script_ids.empty? || device_ids.empty?
      return respond_create_failure(@task, '请至少选择一台设备和一个脚本')
    end

    # 先保存任务本身，再挂关联：join 模型校验 task_id 必须存在
    return respond_create_failure(@task, @task.errors.full_messages.join('；')) unless @task.save

    attach_associations(@task, device_ids, script_ids)
    if @task.save
      respond_to do |format|
        format.json { render json: { success: true, task_id: @task.id, path: task_path(@task) } }
        format.html { redirect_to task_path(@task), notice: '任务已创建，可点击「运行」下发执行' }
      end
    else
      respond_create_failure(@task, @task.errors.full_messages.join('；'))
    end
  end

  # PATCH /tasks/:id
  #
  # 更新名称/描述；若带 device_ids / script_ids，则同时替换所选设备与脚本（对应客户端任务编辑页）。
  def update
    attrs = task_params
    if params.key?(:device_ids) || params.key?(:script_ids)
      attach_associations(@task,
                          Array(params[:device_ids]).reject(&:blank?),
                          Array(params[:script_ids]).reject(&:blank?))
      attrs[:device_count] = @task.network_elements.size
      attrs[:script_count] = @task.scripts.size
    end

    if @task.update(attrs)
      respond_to do |format|
        format.json { render json: { success: true, task_id: @task.id, path: task_path(@task) } }
        format.html { redirect_to task_path(@task), notice: '任务已更新' }
      end
    else
      respond_to do |format|
        format.json { render json: { success: false, errors: @task.errors.full_messages }, status: :unprocessable_entity }
        format.html { redirect_to task_path(@task), alert: @task.errors.full_messages.join('；') }
      end
    end
  end

  # DELETE /tasks/:id
  def destroy
    @task.destroy
    respond_to do |format|
      format.json { render json: { success: true } }
      format.html { redirect_to tasks_path, notice: '任务已删除' }
    end
  end

  # POST /tasks/:id/run
  #
  # 用一条**条件更新**原子抢占"运行中"状态：并发/重复点击时只有一个请求能抢占成功，
  # 避免同时起多个后台执行线程把数据库连接池占满（那会让轮询接口 500）。
  def run
    # 先看进程内注册表：正在执行的线程即使状态被重置成 pending 也不能再起一个
    if TaskRunner.running?(@task.id)
      respond_to do |format|
        format.json { render json: { success: false, error: '任务正在执行中' }, status: :unprocessable_entity }
        format.html { redirect_to task_path(@task), alert: '任务正在执行中' }
      end
      return
    end

    claimed = Task.where(id: @task.id).where.not(status: 'running').update_all(
      status: 'running', progress: 0, started_at: Time.current,
      completed_at: nil, error_message: nil
    )

    if claimed.zero?
      respond_to do |format|
        format.json { render json: { success: false, error: '任务正在执行中' }, status: :unprocessable_entity }
        format.html { redirect_to task_path(@task), alert: '任务正在执行中' }
      end
      return
    end

    @task.reload
    TaskRunner.start_async(@task) # 每次运行新建一条执行记录（保留历史）
    respond_to do |format|
      format.json { render json: { success: true, task_id: @task.id, path: task_path(@task) } }
      format.html { redirect_to task_path(@task), notice: '任务已开始执行，稍后刷新查看结果' }
    end
  end

  # POST /tasks/:id/reset
  #
  # 清空执行记录并回到「待执行」。若任务正在执行，先**协作式取消**后台线程，
  # 否则线程跑完会把状态又写回 completed（用户会看到"重置后又变成完成"）。
  def reset
    TaskRunner.cancel(@task.id) # 逐字复用客户端编排层后为 no-op
    @task.task_runs.destroy_all # 清空执行历史（级联删除其执行单元）
    @task.update_columns(status: 'pending', progress: 0, started_at: nil, completed_at: nil,
                         error_message: nil, result: {})
    respond_to do |format|
      format.json { render json: { success: true, status: 'pending', progress: 0 } }
      format.html { redirect_to task_path(@task), notice: '任务已重置' }
    end
  end

  # GET /tasks/:id/status
  def status
    render json: task_status_payload
  end

  # GET /tasks/:id/report
  def report; end

  # GET /tasks/:id/report_data
  def report_data
    render json: ReportGenerator.call(@task)
  rescue StandardError => e
    render json: { error: "生成报告失败：#{e.message}" }, status: :internal_server_error
  end

  # GET /tasks/:id/export_report?format=json|html|pdf
  def export_report
    data = ReportGenerator.call(@task)

    case params[:format]
    when 'html'
      send_data ReportHtmlGenerator.generate(@task, data),
                filename: "task_report_#{@task.id}.html", type: 'text/html; charset=utf-8', disposition: 'attachment'
    when 'pdf'
      render html: ReportHtmlGenerator.generate(@task, data, print: true).html_safe, layout: false
    else
      send_data JSON.pretty_generate(data),
                filename: "task_report_#{@task.id}.json", type: 'application/json', disposition: 'attachment'
    end
  end

  private

  def set_task
    @task = current_user.tasks.find_by(id: params[:id])
    return if @task

    respond_to do |format|
      format.json { render json: { success: false, error: '任务不存在' }, status: :not_found }
      format.html { redirect_to tasks_path, alert: '任务不存在' }
    end
  end

  def task_params
    params.require(:task).permit(:name, :description)
  end

  def respond_create_failure(task, message)
    respond_to do |format|
      format.json { render json: { success: false, errors: [message] }, status: :unprocessable_entity }
      format.html do
        @task = task
        @scripts = current_user.scripts.order(created_at: :desc)
        @devices = current_user.network_elements.order(created_at: :desc)
        flash.now[:alert] = message
        render :new, status: :unprocessable_entity
      end
    end
  end

  def attach_associations(task, device_ids, script_ids)
    task.scripts = current_user.scripts.where(id: script_ids)
    task.network_elements = current_user.network_elements.where(id: device_ids)
    task.device_count = task.network_elements.size
    task.script_count = task.scripts.size
  end

  def devices_pool
    current_user.network_elements.order(:name).map do |d|
      { id: d.id, name: d.name, device_model: d.device_model, ip_address: d.ip_address }
    end
  end

  def scripts_pool
    current_user.scripts.order(:name).map do |s|
      { id: s.id, name: s.name, description: s.description, device_models: s.device_models }
    end
  end

  def task_json(task)
    run = task.latest_run
    {
      id: task.id, name: task.name, description: task.description,
      status: task.status, status_text: status_text(task.status),
      progress: task.progress, device_count: task.device_count, script_count: task.script_count,
      run_count: task.task_runs.count,
      created_at: task.created_at&.iso8601, started_at: (run ? run.started_at : task.started_at)&.iso8601,
      completed_at: (run ? run.completed_at : task.completed_at)&.iso8601, running: task.running?
    }
  end

  def status_text(status)
    { 'pending' => '等待中', 'running' => '执行中', 'completed' => '已完成',
      'failed' => '失败', 'cancelled' => '已取消' }[status.to_s] || status.to_s
  end

  def unit_status_text(status)
    { 'pending' => '待执行', 'running' => '执行中',
      'completed' => '已完成', 'failed' => '失败' }[status.to_s] || status.to_s
  end

  def task_status_payload
    run = @task.latest_run
    scope = run ? run.task_executions : @task.task_executions
    executions = scope.includes(:script, :network_element).to_a
    by_device = executions.group_by(&:network_element_id)

    units = @task.network_elements.map do |device|
      build_unit(device, (by_device[device.id] || []).sort_by(&:script_id))
    end

    {
      id: @task.id, name: @task.name, description: @task.description,
      run_id: run&.id, run_count: @task.task_runs.count,
      status: run ? run.status : @task.status,
      status_text: status_text(run ? run.status : @task.status),
      progress: run ? run.progress : @task.progress,
      device_count: @task.device_count, script_count: @task.script_count,
      created_at: @task.created_at,
      started_at: run ? run.started_at : @task.started_at,
      completed_at: run ? run.completed_at : @task.completed_at,
      error_message: run ? run.error_message : @task.error_message,
      running: run ? run.running? : @task.running?,
      execution_units: units
    }
  end

  def build_unit(device, execs)
    terminal = %w[completed partial failed error]
    total = execs.size
    done = execs.count { |e| terminal.include?(e.status) }
    running = execs.find { |e| e.status == 'running' }
    progress = total.zero? ? 0 : ((done * 100.0) / total).round

    unit_status =
      if running
        'running'
      elsif total.positive? && done == total
        execs.any? { |e| %w[failed error].include?(e.status) } ? 'failed' : 'completed'
      elsif done.positive?
        'running'
      else
        'pending'
      end

    {
      id: device.id, device_name: device.name, device_ip: device.ip_address,
      description: device.description,
      status: unit_status, status_text: unit_status_text(unit_status), progress: progress,
      current_script: running&.script&.name,
      scripts: execs.map { |e| script_payload(e) }
    }
  end

  # 脚本状态：客户端执行器已给出四态（completed/partial/failed/error/pending/running），直接用
  def script_payload(exec)
    result = exec.result.is_a?(Hash) ? exec.result : {}
    {
      name: exec.script&.name,
      # 供「改进脚本」调用 /scripts/improve_description 使用
      script_uid: exec.script&.script_uid,
      script_description: exec.script&.description,
      script_prompt: exec.script&.initial_prompt,
      status: display_script_status(exec, result),
      conclusion: conclusion_of(result),
      checkpoints: result['checkpoints'] || [],
      error: exec.error_message,
      logs: devlog_content(exec) || exec.logs,
      output: devlog_content(exec) || exec.logs,
      started_at: exec.started_at, completed_at: exec.finished_at,
      duration: exec.duration_seconds
    }
  end

  # 读取该脚本的运行日志文件（客户端 ScriptExecutor 边执行边写 devlog.txt）。
  # 这样运行中轮询 /status 就能看到持续增长的日志——与客户端"读文件"的做法一致。
  def devlog_content(exec)
    run = @task.latest_run
    return nil unless run&.started_at && exec.network_element && exec.script

    dir = "task_#{@task.id}_#{run.started_at.strftime('%Y%m%d_%H%M%S')}"
    path = FilePathUtils.devlog_file_path(
      dir, exec.network_element.ip_address.to_s, exec.script.name,
      base_logs_dir: Rails.root.join('logs').to_s
    )
    return nil unless File.exist?(path)

    content = File.read(path)
    content.empty? ? nil : content
  rescue StandardError
    nil
  end

  def conclusion_of(result)
    # 客户端执行器把结论直接写进 result['conclusion']；兼容历史数据再从 status 推
    return result['conclusion'] if result['conclusion'].present?

    case result['status']
    when 'all_passed' then 'success'
    when 'some_failed' then 'partial'
    when 'error' then 'error'
    end
  end

  def display_script_status(exec, _result)
    exec.status
  end
end
