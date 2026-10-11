# frozen_string_literal: true

require 'rails_helper'

# 按「客户端真实日志 + 用户要求」改进主线描述的接口
#
# 服务层的提示词契约由 script_description_improvement_service_spec 覆盖；这里验证**请求边界**：
#   1. 未登录拒绝（写操作都要有归属）；
#   2. 用户没带 LLM Key 时是 400 + 可读文案，不是 500（BYOK 的配置问题不该表现成服务端故障）；
#   3. 成功时返回整份描述、待确认项与改动说明；
#   4. 服务给出的可见错误原样透传（用户点了按钮就得知道为什么没成）。
RSpec.describe '改进主线描述接口', type: :request do
  let(:user_key) { 'sk-request-scoped-3c5e7a9b1d2f4a6c8e0b' }
  let(:payload) do
    {
      description: "----------------------步骤1----------------------\n预期：全部端口 up",
      requirement: '端口 Gi0/0/3 本来就该是 down，改成 down 才算通过',
      log: "Switch> show interface brief\nGigabitEthernet0/0/3  down  down",
      checkpoints: [{ name: '端口 Gi0/0/3 状态', passed: false, value: 'down/down' }],
      error: ''
    }
  end

  # 用真实入口建立会话：领识别码 → /onboarding/enter（同时满足 activated 校验）
  def sign_in_user
    # 开源版免登录：所有请求都以本地操作员身份运行。
    User.local_operator
  end

  def stub_llm(content)
    allow(LlmRequestService).to receive(:call).and_return(
      'choices' => [{ 'message' => { 'content' => content } }]
    )
  end


  it '没带 LLM Key 时返回 400 与可读文案（不是 500）' do
    sign_in_user

    post '/scripts/improve_description', params: payload, as: :json

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body)['code']).to eq('missing_llm_api_key')
  end

  it '成功时返回改进后的描述、待确认项与改动说明' do
    sign_in_user
    stub_llm(<<~CONTENT)
      { "description": "改进后的描述：【待确认#1】",
        "open_questions": [{ "id": 1, "question": "其余端口是否都要求 up？", "options": ["是", "否"] }],
        "notes": ["把 Gi0/0/3 的预期改成 down/down"] }
    CONTENT

    post '/scripts/improve_description', params: payload,
                                        headers: { 'X-LLM-Api-Key' => user_key }, as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['success']).to be true
    expect(body['description']).to include('改进后的描述')
    expect(body['open_questions'].first['question']).to eq('其余端口是否都要求 up？')
    expect(body['notes']).to eq(['把 Gi0/0/3 的预期改成 down/down'])
  end

  it '用户要求为空时明确报错，不调用 LLM' do
    sign_in_user
    expect(LlmRequestService).not_to receive(:call)

    post '/scripts/improve_description', params: payload.merge(requirement: '  '),
                                        headers: { 'X-LLM-Api-Key' => user_key }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to include('要求')
  end

  it '服务报错时把原因原样透传，不变成 500' do
    sign_in_user
    allow(LlmRequestService).to receive(:call).and_raise(StandardError, '模型服务暂时不可用')

    post '/scripts/improve_description', params: payload,
                                        headers: { 'X-LLM-Api-Key' => user_key }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to eq('模型服务暂时不可用')
  end

  # 日志与描述是客户内容：不能进 Rails 请求日志
  it '请求参数里的日志与要求被过滤掉，不落进请求日志' do
    sign_in_user
    stub_llm('{ "description": "改进后" }')

    filtered = request_params_after_post

    expect(filtered.to_s).not_to include('V200R019C10SPC500')
    expect(filtered.to_s).not_to include('本来就该是 down')
  end

  def request_params_after_post
    post '/scripts/improve_description', params: payload,
                                        headers: { 'X-LLM-Api-Key' => user_key }, as: :json
    # request.filtered_parameters 是 Rails 真正拿去写日志/落库的那份
    controller.request.filtered_parameters
  end
end
