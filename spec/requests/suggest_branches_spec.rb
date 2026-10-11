# frozen_string_literal: true

require 'rails_helper'

# AI 建议分支接口
#
# 这里验证请求边界的**参数透传**：带 custom_requirement 时走上「自定义场景」提示词，
# 不带时仍走默认路径（恰好 3 条）。生成本身的解析/校验由 branch_suggestion_service_spec 覆盖。
RSpec.describe 'AI 建议分支接口', type: :request do
  def sign_in_user
    # 开源版免登录：所有请求都以本地操作员身份运行。
    User.local_operator
  end

  def stub_consistency_ok
    allow(BranchConsistencyService).to receive(:new) do |_description, branches|
      results = Array(branches).each_with_index.map do |branch, index|
        { index: index, name: branch[:name], verdict: 'ok', reason: '', offending: [] }
      end
      instance_double(BranchConsistencyService, call: { success: true, results: results, has_issues: false, error: nil })
    end
  end

  before { stub_consistency_ok }

  def post_suggestions(body)
    post '/scripts/suggest_branches', params: body, as: :json
  end

  it '带 custom_requirement：按用户场景生成（这里给 1 条就返回 1 条）' do
    sign_in_user
    captured = nil
    allow(LlmRequestService).to receive(:call) do |messages:, **|
      captured = messages.last[:content]
      { 'choices' => [{ 'message' => { 'content' => '{"branches":[{"name":"权限不足","description":"设备提示权限不足的完整流程"}]}' } }] }
    end

    post_suggestions(description: '巡检交换机', custom_requirement: '设备返回权限不足')

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['success']).to be true
    expect(body['branches'].size).to eq(1)
    expect(captured).to include('设备返回权限不足')
    expect(captured).to include('条数由用户描述决定')
  end

  it '不带 custom_requirement：仍走默认路径（固定 3 条的要求）' do
    sign_in_user
    captured = nil
    allow(LlmRequestService).to receive(:call) do |messages:, **|
      captured = messages.last[:content]
      { 'choices' => [{ 'message' => { 'content' => '{"branches":[{"name":"a","description":"d"}]}' } }] }
    end

    post_suggestions(description: '巡检交换机')

    expect(response).to have_http_status(:ok)
    expect(captured).to include('恰好 3 条')
  end

  it 'custom_requirement 为空白时按默认路径处理' do
    sign_in_user
    captured = nil
    allow(LlmRequestService).to receive(:call) do |messages:, **|
      captured = messages.last[:content]
      { 'choices' => [{ 'message' => { 'content' => '{"branches":[{"name":"a","description":"d"}]}' } }] }
    end

    post_suggestions(description: '巡检交换机', custom_requirement: '   ')

    expect(response).to have_http_status(:ok)
    expect(captured).to include('恰好 3 条')
  end
end
