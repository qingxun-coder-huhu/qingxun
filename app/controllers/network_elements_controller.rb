# frozen_string_literal: true

require_relative '../services/task_runner'

# 设备管理（开源版）
#
# 与线上版不同：连接凭据（IP/账号/密码）与设备信息存在同一处（单一应用），
# 密码列由模型层加密存储。提供 HTML 与 JSON 两种响应：
#   - JSON：供 Vue 页（设备管理）调用；
#   - HTML：保留为无 JS 时的回退（表单提交 + flash）。
class NetworkElementsController < ApplicationController
  before_action :set_network_element, only: [:edit, :update, :destroy, :test_connection, :execute]

  # GET /network_elements
  def index
    @network_elements = current_user.network_elements.order(created_at: :desc)
    @network_element = current_user.network_elements.new
    @scripts = current_user.scripts.order(created_at: :desc)

    respond_to do |format|
      format.html
      format.json { render json: @network_elements.map { |d| device_json(d) } }
    end
  end

  def new
    @network_element = current_user.network_elements.new
  end

  def edit; end

  # POST /network_elements
  def create
    @network_element = current_user.network_elements.new(network_element_params)
    saved = @network_element.save

    respond_to do |format|
      format.json do
        if saved
          render json: { success: true, device: device_json(@network_element) }
        else
          render json: { success: false, errors: @network_element.errors.full_messages }, status: :unprocessable_entity
        end
      end
      format.html do
        if saved
          redirect_to network_elements_path, notice: '设备已创建'
        else
          @network_elements = current_user.network_elements.order(created_at: :desc)
          render :index, status: :unprocessable_entity
        end
      end
    end
  end

  # PATCH/PUT /network_elements/:id
  def update
    # 密码留空表示"不修改"
    attrs = network_element_params
    %i[password enable_password root_password].each { |f| attrs.delete(f) if attrs[f].blank? }
    saved = @network_element.update(attrs)

    respond_to do |format|
      format.json do
        if saved
          render json: { success: true, device: device_json(@network_element) }
        else
          render json: { success: false, errors: @network_element.errors.full_messages }, status: :unprocessable_entity
        end
      end
      format.html do
        if saved
          redirect_to network_elements_path, notice: '设备已更新'
        else
          render :edit, status: :unprocessable_entity
        end
      end
    end
  end

  # DELETE /network_elements/:id
  def destroy
    @network_element.destroy
    respond_to do |format|
      format.json { render json: { success: true } }
      format.html { redirect_to network_elements_path, notice: '设备已删除' }
    end
  end

  # POST /network_elements/:id/test_connection
  def test_connection
    require_relative '../../lib/telnet_device' unless defined?(TelnetDevice)
    timeout = params[:timeout].presence&.to_i || 60
    result = TelnetDevice.test_conn(@network_element, timeout)

    respond_to do |format|
      format.json do
        render json: { success: true, status: result[:status], protocol: result[:protocol],
                       message: result[:message], login_steps: result[:login_steps] }
      end
      format.html do
        redirect_to network_elements_path, notice: "连接测试：#{result[:message]}（#{result[:status]}）"
      end
    end
  end

  # POST /network_elements/:id/execute
  #
  # 单台设备执行所选的脚本：建任务并后台下发（结果在任务详情查看）。
  def execute
    ids = Array(params[:script_ids]).reject(&:blank?)
    if ids.empty?
      respond_to do |format|
        format.json { render json: { success: false, error: '请选择要执行的脚本' }, status: :unprocessable_entity }
        format.html { redirect_to network_elements_path, alert: '请选择要执行的脚本' }
      end
      return
    end

    task = build_task([@network_element], ids)
    if task.nil?
      respond_to do |format|
        format.json { render json: { success: false, error: '创建任务失败' }, status: :unprocessable_entity }
        format.html { redirect_to network_elements_path, alert: '创建任务失败' }
      end
      return
    end

    TaskRunner.start_async(task)
    respond_to do |format|
      format.json { render json: { success: true, task_id: task.id, path: task_path(task) } }
      format.html { redirect_to task_path(task), notice: '已开始执行，稍后在任务详情查看结果' }
    end
  end

  # POST /network_elements/execute_batch
  #
  # 多台设备批量执行所选脚本（客户端「选中多台 → 执行脚本」的对应实现）。
  def execute_batch
    device_ids = Array(params[:device_ids]).reject(&:blank?)
    script_ids = Array(params[:script_ids]).reject(&:blank?)
    devices = current_user.network_elements.where(id: device_ids)

    if devices.empty? || script_ids.empty?
      return render json: { success: false, error: '请选择设备与脚本' }, status: :unprocessable_entity
    end

    task = build_task(devices.to_a, script_ids)
    return render json: { success: false, error: '创建任务失败' }, status: :unprocessable_entity if task.nil?

    TaskRunner.start_async(task)
    render json: { success: true, task_id: task.id, path: task_path(task) }
  end

  private

  def set_network_element
    @network_element = current_user.network_elements.find_by(id: params[:id])
    return if @network_element

    respond_to do |format|
      format.json { render json: { success: false, error: '设备不存在' }, status: :not_found }
      format.html { redirect_to network_elements_path, alert: '设备不存在' }
    end
  end

  def network_element_params
    params.require(:network_element).permit(
      :name, :device_model, :description, :active,
      :ip_address, :port, :connection_type, :username,
      :password, :enable_command, :enable_password, :root_password, :ssh_key_path
    )
  end

  def device_json(device)
    {
      id: device.id, name: device.name, device_model: device.device_model,
      ip_address: device.ip_address, port: device.port, connection_type: device.connection_type,
      username: device.username,
      has_password: device.password.present?,
      has_enable_password: device.enable_password.present?,
      has_root_password: device.root_password.present?,
      enable_command: device.enable_command, description: device.description, active: device.active,
      created_at: device.created_at&.iso8601
    }
  end

  # 建任务：多设备 + 多脚本（供批量执行复用）
  def build_task(devices, script_ids)
    task = current_user.tasks.new(name: "设备执行-#{devices.map(&:name).join('/')}-#{Time.current.strftime('%m%d%H%M%S')}",
                                  description: "在 #{devices.size} 台设备上执行脚本")
    return nil unless task.save

    task.scripts = current_user.scripts.where(id: script_ids)
    task.network_elements = devices
    task.device_count = devices.size
    task.script_count = task.scripts.size
    task.save ? task : nil
  end
end
