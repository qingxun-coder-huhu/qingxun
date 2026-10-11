# frozen_string_literal: true

# 设备型号管理
#
# 业务逻辑：
#   用户在此维护自己的设备型号清单，脚本生成页的"支持的设备型号"从这里取候选。
#   型号是脚本与设备匹配的依据，先维护一份统一写法的清单，避免手输导致的匹配落空。
#
# 安全设计：
#   2. 所有查询都经 current_user.device_models，天然按用户隔离，找不到即视为无权。
class DeviceModelsController < ApplicationController
  before_action :set_device_model, only: [:edit, :update, :destroy]

  # GET /device_models
  def index
    @device_models = current_user.device_models.ordered
    @device_model = current_user.device_models.new
  end

  # POST /device_models
  def create
    @device_model = current_user.device_models.new(device_model_params)

    if @device_model.save
      redirect_to device_models_path, notice: '设备型号已添加'
    else
      @device_models = current_user.device_models.ordered
      render :index, status: :unprocessable_entity
    end
  end

  # GET /device_models/:id/edit
  def edit
  end

  # PATCH/PUT /device_models/:id
  def update
    if @device_model.update(device_model_params)
      redirect_to device_models_path, notice: '设备型号已更新'
    else
      @device_models = current_user.device_models.ordered
      render :index, status: :unprocessable_entity
    end
  end

  # DELETE /device_models/:id
  def destroy
    @device_model.destroy
    redirect_to device_models_path, notice: '设备型号已删除'
  end

  private

  def set_device_model
    @device_model = current_user.device_models.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to device_models_path, alert: '设备型号不存在或无权访问'
  end

  def device_model_params
    params.require(:device_model).permit(:name)
  end
end
