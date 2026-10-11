# frozen_string_literal: true

require 'rdoc'
require 'rdoc/markdown'
require 'rdoc/markup/to_html'

# Markdown → HTML（用 Ruby 自带的 rdoc，避免引入 gem）
#
# 隐性知识：
#   1. 项目没有 markdown gem，而部署机不同步 vendor/bundle，加 gem 需要重建镜像、代价大，
#      所以文章渲染用 stdlib 的 rdoc（`RDoc::Markdown`，支持表格、围栏代码块）。
#   2. `output_decoration = true` 保留标题 id（便于锚点引用）；`pipe = true` 关掉 rdoc 默认
#      给标题附加的 "¶ ↑" 装饰——对公开文章页是噪音。
#   3. rdoc 会**原样透传**正文里的 HTML；文章由我们自己撰写，可接受。
module MarkdownRenderer
  def self.render(markdown)
    options = RDoc::Options.new
    options.output_decoration = true
    options.pipe = true
    document = RDoc::Markdown.new.parse(markdown.to_s)
    RDoc::Markup::ToHtml.new(options).convert(document)
  end
end
