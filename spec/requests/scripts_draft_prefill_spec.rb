# frozen_string_literal: true

require 'rails_helper'

# 首页 Hero「生成需求描述」的目标与日志交接
#
# 背景（用户要求）：这段交接原来写进浏览器 sessionStorage，但日志最多 4 万字、本身就是设备回显，
# 不该在浏览器里留副本。现在改成**表单 POST** 给 /scripts：内容只随这一次请求走，
# 服务端只在这次渲染里注入 JSON（#draft-prefill），不落库、不落 cookie/session、不落浏览器存储。
# 刷新即为空表单（需要就回首页重新触发）—— 这是有意的取舍。
RSpec.describe '首页交接的目标与日志（POST /scripts）', type: :request do
  it 'POST 带目标与日志：渲染进页面（#draft-prefill）' do
    post '/scripts', params: { draft_goal: '核对端口状态', draft_log: "Switch# show interfaces status\nGi0/3 notconnect" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="draft-prefill"')
    expect(response.body).to include('核对端口状态')
    expect(response.body).to include('Gi0/3 notconnect')
  end

  it 'GET（不带）时没有预填数据' do
    get '/scripts'
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('id="draft-prefill"')
  end

  it '两者都空时忽略' do
    post '/scripts', params: { draft_goal: '   ', draft_log: '' }
    expect(response.body).not_to include('id="draft-prefill"')
  end

  it '异常大的请求体整体忽略（不做截断，避免用户以为日志被完整带过来）' do
    post '/scripts', params: { draft_log: 'x' * 1_000_001 }
    expect(response.body).not_to include('id="draft-prefill"')
  end

end
