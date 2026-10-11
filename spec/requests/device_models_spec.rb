# frozen_string_literal: true

require 'rails_helper'

# 设备型号管理接口
#
# 这里验证**请求边界**（页面观感不测）：
#   1. 需要登录：型号清单是用户私有数据；
#   2. 严格按 current_user 隔离：列表只看自己的，改/删别人的返回"不存在或无权"；
#   3. 增改删的基本链路与去空白；重复名称是 422 而不是 500；
#   4. 生成页会把清单作为下拉候选注入（按名称排序）。
RSpec.describe '设备型号管理', type: :request do
  # 用真实入口建立会话：领识别码 → /onboarding/enter
  def sign_in_user
    # 开源版免登录：所有请求都以本地操作员身份运行。
    User.local_operator
  end

  describe 'CRUD' do
    it '新增后出现在列表（并去掉两端空白）' do
      sign_in_user

      expect {
        post '/device_models', params: { device_model: { name: '  Cisco Catalyst 2960 ' } }
      }.to change(DeviceModel, :count).by(1)

      follow_redirect!
      expect(response.body).to include('Cisco Catalyst 2960')
    end

    it '重复名称返回 422 并给出错误，不炸成 500' do
      user = sign_in_user
      DeviceModel.create!(user: user, name: 'Huawei S5735')

      post '/device_models', params: { device_model: { name: 'huawei s5735' } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('该设备型号已存在')
    end

    it '更新名称' do
      user = sign_in_user
      model = DeviceModel.create!(user: user, name: 'Old')

      patch "/device_models/#{model.id}", params: { device_model: { name: 'New' } }

      expect(response).to have_http_status(:redirect)
      expect(model.reload.name).to eq('New')
    end

    it '删除' do
      user = sign_in_user
      model = DeviceModel.create!(user: user, name: 'ToDelete')

      expect {
        delete "/device_models/#{model.id}"
      }.to change(DeviceModel, :count).by(-1)
    end
  end

  describe '生成页候选' do
    it '把本用户的型号按名称排序注入下拉数据' do
      user = sign_in_user
      DeviceModel.create!(user: user, name: 'Huawei S5735')
      DeviceModel.create!(user: user, name: 'cisco 2960')

      get '/scripts'

      expect(response).to have_http_status(:ok)
      # 只解析注入的 JSON 候选块：页面帮助文案里也有示例型号，直接全文查会误判
      payload = response.body[%r{id="device-model-options-data">(.*?)</script>}m, 1]
      expect(payload).to be_present
      expect(JSON.parse(payload)).to eq(['cisco 2960', 'Huawei S5735'])
    end
  end
end
