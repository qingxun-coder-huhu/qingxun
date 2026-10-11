# frozen_string_literal: true

require 'rails_helper'

# 脚本版本号：重新生成涨 minor、微调涨 patch
#
# 背景（实测踩过）：`scripts.version` 长期恒为 '1.0.0' —— 另一个会递增的 `revision` 是
# **快照序号**，只在需求文本变化时才动（只改代码的微调不会动它），而且从没被任何 API 暴露，
# 于是客户端下载到的版本号永远不变，"微调后版本应该变"这条无从体现。
#
# 这里钉住的契约：
#   1. 重新生成（source=generated）→ minor+1、patch 归零；
#   2. 微调（source=refined）→ patch+1；
#   3. **普通自动保存（source=autosave）不涨** —— 用户每敲几个字就 autosave 一次，跟着涨就是噪声；
#   4. 伪造/未知来源（服务端只认 generated/refined，其余一律降级为 autosave）同样不涨；
#   5. 版本号要在 autosave 的响应里回给页面（状态行显示 vX.Y.Z），客户端拉脚本时拿到的也是它。
RSpec.describe '脚本版本号推进', type: :request do
  let(:script_uid) { SecureRandom.hex(8) }
  let(:code) { "class VersionSpec < Qingxun::DeviceScript\n  def run; end\nend" }

  # 用真实入口建立会话：领识别码 → /onboarding/enter
  def sign_in_user
    # 开源版免登录：所有请求都以本地操作员身份运行。
    User.local_operator
  end

  def autosave(source:, code_value: code, description: '检查设备版本')
    post '/scripts/autosave', params: {
      script_uid: script_uid,
      script_name: '版本号脚本',
      script_description: '测试版本号',
      initial_prompt: description,
      device_models: 'ZXCTN 9000',
      code: code_value,
      command_mapping: '[]',
      branch_scenarios: '[]',
      source: source
    }, as: :json
    JSON.parse(response.body)
  end

  before { sign_in_user }

  it '首次生成：minor 涨一位、patch 归零' do
    body = autosave(source: 'generated')

    expect(body['success']).to be true
    expect(body['version']).to eq('1.1.0')
    expect(Script.find_by(script_uid: script_uid).version).to eq('1.1.0')
  end

  it '微调：patch 涨一位（已生成的脚本上再点微调）' do
    autosave(source: 'generated')          # 1.1.0
    body = autosave(source: 'refined', description: '检查设备版本，并核对 CPU')

    expect(body['version']).to eq('1.1.1')
  end

  it '连续微调：patch 继续累加，minor 不动' do
    autosave(source: 'generated')                                      # 1.1.0
    autosave(source: 'refined', description: '第一次微调')               # 1.1.1
    body = autosave(source: 'refined', description: '第二次微调')        # 1.1.2

    expect(body['version']).to eq('1.1.2')
  end

  it '再点一次重新生成：minor 再涨一位、patch 归零' do
    autosave(source: 'generated')                                  # 1.1.0
    autosave(source: 'refined', description: '微调一下')            # 1.1.1
    body = autosave(source: 'generated', description: '重新生成一版')  # 1.2.0

    expect(body['version']).to eq('1.2.0')
  end

  it '普通自动保存（用户敲字）不动版本号' do
    autosave(source: 'generated')                                  # 1.1.0
    body = autosave(source: 'autosave', code_value: "#{code}\n# 改一行")

    expect(body['version']).to eq('1.1.0')
  end

  # 服务端只认 generated / refined，其余（含伪造的 manual）一律降级为 autosave（见 scripts_controller.rb）
  it '伪造/未知来源不涨版本号' do
    autosave(source: 'generated')                                  # 1.1.0
    body = autosave(source: 'manual')

    expect(body['version']).to eq('1.1.0')
  end

  it '响应里带上版本号，页面状态行才能显示 vX.Y.Z' do
    body = autosave(source: 'refined')

    expect(body).to have_key('version')
    expect(body['version']).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
