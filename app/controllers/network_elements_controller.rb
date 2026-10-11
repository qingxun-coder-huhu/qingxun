# frozen_string_literal: true

# 设备管理（开源版）
#
# 与线上版不同：连接凭据（IP/账号/密码）与设备信息存在同一处（单一应用），
# 密码列由模型层加密存储。这里提供增删改查与「测试连接」。
class NetworkElementsController < ApplicationController
  before_action :set_network_element, only: [:edit, :update, :destroy, :test_connection]

  # GET /network_elements
  def index
    @network_elements = current_user.network_elements.order(created_at: :desc)
    @network_element = current_user.network_elements.new
  end

  # GET /network_elements/new
  def new
    @network_element = current_user.network_elements.new
  end

  # GET /network_elements/:id/edit
  def edit; end

  # POST /network_elements
  def create
    @network_element = current_user.network_elements.new(network_element_params)
    if @network_element.save
      redirect_to network_elements_path, notice: '设备已创建'
    else
      @network_elements = current_user.network_elements.order(created_at: :desc)
      render :index, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /network_elements/:id
  def update
    # 密码留空表示"不修改"
    attrs = network_element_params
    %i[password enable_password root_password].each do |field|
      attrs.delete(field) if attrs[field].blank?
    end

    if @network_element.update(attrs)
      redirect_to network_elements_path, notice: '设备已更新'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /network_elements/:id
  def destroy
    @network_element.destroy
    redirect_to network_elements_path, notice: '设备已删除'
  end

  # POST /network_elements/:id/test_connection
  def test_connection
    require_relative '../../lib/telnet_device' unless defined?(TelnetDevice)
    result = TelnetDevice.test_conn(@network_element, 30)
    redirect_to network_elements_path,
                notice: "连接测试：#{result[:message]}（#{result[:status]}）"
  end

  private

  def set_network_element
    @network_element = current_user.network_elements.find_by(id: params[:id])
    redirect_to network_elements_path, alert: '设备不存在' unless @network_element
  end

  def network_element_params
    params.require(:network_element).permit(
      :name, :device_model, :description, :active,
      :ip_address, :port, :connection_type, :username,
      :password, :enable_command, :enable_password, :root_password, :ssh_key_path
    )
  end
end
