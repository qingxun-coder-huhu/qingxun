# frozen_string_literal: true

require_relative '../services/task_runner'

# 任务管理（开源版）
#
# 任务 = 若干「设备 × 脚本」的组合。本控制器负责：
#   - 列表 / 详情 / 创建 / 删除；
#   - 「运行」：交给 TaskRunner 在后台并发下发到真机执行，页面轮询查看进度与结果。
#
# 与线上版的差异：线上版把执行放到本地客户端，这里执行就在同一应用内完成。
class TasksController < ApplicationController
  before_action :set_task, only: [:show, :run, :destroy]

  # GET /tasks
  def index
    @tasks = current_user.tasks.order(created_at: :desc)
  end

  # GET /tasks/:id
  def show
    @executions = @task.task_executions.includes(:script, :network_element).ordered
  end

  # GET /tasks/new
  def new
    @task = current_user.tasks.new
    @scripts = current_user.scripts.order(created_at: :desc)
    @devices = current_user.network_elements.order(created_at: :desc)
  end

  # POST /tasks
  def create
    @task = current_user.tasks.new(name: task_params[:name], description: task_params[:description])

    script_ids = Array(params[:script_ids]).reject(&:blank?)
    device_ids = Array(params[:device_ids]).reject(&:blank?)

    if script_ids.empty? || device_ids.empty?
      @scripts = current_user.scripts.order(created_at: :desc)
      @devices = current_user.network_elements.order(created_at: :desc)
      flash.now[:alert] = '请至少选择一台设备和一个脚本'
      return render :new, status: :unprocessable_entity
    end

    # 先保存任务本身，再挂关联：join 模型校验 task_id 必须存在，
    # 在父记录尚未落库前赋值会触发 "Task can't be blank"。
    unless @task.save
      @scripts = current_user.scripts.order(created_at: :desc)
      @devices = current_user.network_elements.order(created_at: :desc)
      return render :new, status: :unprocessable_entity
    end

    @task.scripts = current_user.scripts.where(id: script_ids)
    @task.network_elements = current_user.network_elements.where(id: device_ids)
    @task.device_count = @task.network_elements.size
    @task.script_count = @task.scripts.size

    if @task.save
      redirect_to task_path(@task), notice: '任务已创建，可点击「运行」下发执行'
    else
      @scripts = current_user.scripts.order(created_at: :desc)
      @devices = current_user.network_elements.order(created_at: :desc)
      render :new, status: :unprocessable_entity
    end
  end

  # POST /tasks/:id/run
  def run
    if @task.running?
      redirect_to task_path(@task), alert: '任务正在执行中'
      return
    end

    @task.task_executions.destroy_all
    TaskRunner.start_async(@task)
    redirect_to task_path(@task), notice: '任务已开始执行，稍后刷新查看结果'
  end

  # DELETE /tasks/:id
  def destroy
    @task.destroy
    redirect_to tasks_path, notice: '任务已删除'
  end

  private

  def set_task
    @task = current_user.tasks.find_by(id: params[:id])
    redirect_to tasks_path, alert: '任务不存在' unless @task
  end

  def task_params
    params.require(:task).permit(:name, :description)
  end
end
