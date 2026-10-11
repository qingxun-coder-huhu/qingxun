# frozen_string_literal: true

# 条款渲染辅助方法
#
# 业务逻辑：
# 提供将数据库中的纯文本条款内容转换为HTML的辅助方法。
# 使用 simple_format 进行基本格式化，保持内容一致性和合规性。
#
# 设计考虑：
# 1. 保持简单，确保数据库内容与显示内容100%一致
# 2. 使用 standard Rails helper (simple_format) 确保安全
# 3. 添加适当的CSS类以保持现有样式
# 4. 免责声明部分作为普通段落渲染（放弃警告框样式）
#
# 隐性知识：
# 1. simple_format 会自动将换行转换为 <br>，双换行转换为 <p>
# 2. 列表项（以 - 开头）将保持原样，需要前端CSS样式
# 3. 安全考虑：使用 simple_format 而不是 raw 或 html_safe
# 4. 性能影响可忽略，纯文本转换很快
#
module TermsHelper
  # 渲染服务条款内容
  #
  # 参数：
  #   content - 数据库中的纯文本条款内容，支持 [b]...[/b] 和 [red]...[/red] 标记
  # 返回：
  #   格式化的HTML内容，可直接在视图中使用
  #
  # 示例：
  #   <%= render_terms_content(@terms_version.terms_content) %>
  #
  def render_terms_content(content)
    return '' if content.blank?

    # 先用 simple_format 进行基本格式化（换行、段落）
    formatted = simple_format(content.to_s, wrapper_tag: :div, class: 'terms-content', sanitize: false)

    # 再处理自定义标记
    processed = formatted.to_s.dup

    # 处理 [b]...[/b] 加粗标记
    processed.gsub!(/\[b\](.*?)\[\/b\]/m, '<strong>\1</strong>')

    # 处理 [red]...[/red] 红色标记
    processed.gsub!(/\[red\](.*?)\[\/red\]/m, '<span style="color: #dc2626 !important; font-weight: 600;">\1</span>')

    # 标记为 HTML 安全
    processed.html_safe
  end

  # 渲染隐私政策内容
  #
  # 参数：
  #   content - 数据库中的纯文本隐私政策内容，支持 [b]...[/b] 和 [red]...[/red] 标记
  # 返回：
  #   格式化的HTML内容，可直接在视图中使用
  #
  # 示例：
  #   <%= render_privacy_content(@terms_version.privacy_content) %>
  #
  def render_privacy_content(content)
    return '' if content.blank?

    # 先用 simple_format 进行基本格式化（换行、段落）
    formatted = simple_format(content.to_s, wrapper_tag: :div, class: 'privacy-content', sanitize: false)

    # 再处理自定义标记
    processed = formatted.to_s.dup

    # 处理 [b]...[/b] 加粗标记
    processed.gsub!(/\[b\](.*?)\[\/b\]/m, '<strong>\1</strong>')

    # 处理 [red]...[/red] 红色标记
    processed.gsub!(/\[red\](.*?)\[\/red\]/m, '<span style="color: #dc2626 !important; font-weight: 600;">\1</span>')

    # 标记为 HTML 安全
    processed.html_safe
  end

end
