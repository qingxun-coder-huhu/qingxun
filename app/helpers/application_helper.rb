module ApplicationHelper
  # 规范来源：canonical / sitemap 一律用它拼接，而不是 request.base_url。
  #
  # 开源版：取部署时配置的站点地址（ENV SITE_ORIGIN），未配置时回落到访问域名，
  # 这样自建部署不必改代码即可生成正确的规范链接。
  def canonical_origin
    ENV['SITE_ORIGIN'].presence || request.base_url
  end

  # 页面的规范 URL（只取路径，丢掉查询串）：?utm_*、?script_uid= 等不应被当成不同页面
  def canonical_url(path = request.path)
    "#{canonical_origin}#{path}"
  end

  # 获取会话状态对应的Bootstrap徽章样式和文本
  def status_badge(status)
    status_config = {
      'welcome' => { class: 'bg-info', text: '欢迎' },
      'collecting' => { class: 'bg-primary', text: '收集中' },
      'clarifying' => { class: 'bg-warning text-dark', text: '澄清中' },
      'processing' => { class: 'bg-primary', text: '处理中' },
      'testing' => { class: 'bg-info', text: '测试中' },
      'evaluating' => { class: 'bg-info', text: '评估中' },
      'reevaluating' => { class: 'bg-info', text: '重新评估中' },
      'complete' => { class: 'bg-success', text: '已完成' },
      'queued' => { class: 'bg-info', text: '队列中' },
      'failed' => { class: 'bg-danger', text: '失败' }
    }
    config = status_config[status.to_s] || { class: 'bg-secondary', text: status.to_s }
    content_tag(:span, config[:text], class: "badge #{config[:class]}")
  end
end

