# frozen_string_literal: true

# 报告 HTML 生成（开源版）
#
# 用于「导出 HTML」与「导出 PDF」：后者内联打开打印优化版并自动呼出打印对话框，
# 用户在对话框里选「另存为 PDF」（避免服务端生成中文 PDF 的字体依赖）。
# 结构对齐客户端 ReportHtmlGenerator。
module ReportHtmlGenerator
  PRINT_CSS = <<~CSS
    .print-toolbar {
      position: sticky; top: 0; z-index: 10;
      display: flex; align-items: center; justify-content: space-between; gap: 12px;
      padding: 10px 16px; margin-bottom: 16px;
      background: #ecf5ff; border: 1px solid #b3d8ff; border-radius: 6px;
      color: #409eff; font-size: 14px;
    }
    .print-toolbar button {
      flex-shrink: 0; padding: 6px 14px; border: none; border-radius: 4px;
      background: #409eff; color: #fff; font-size: 14px; cursor: pointer;
    }
    @page { size: A4; margin: 12mm; }
    @media print {
      * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      body { background: #fff; padding: 0; }
      .container { max-width: none; box-shadow: none; border-radius: 0; padding: 0; }
      .no-print { display: none !important; }
      .device-card, tr, .checkpoint-item { break-inside: avoid; page-break-inside: avoid; }
      thead { display: table-header-group; }
      h2 { break-after: avoid; page-break-after: avoid; }
    }
  CSS

  PRINT_TOOLBAR = <<~HTML
    <div class="no-print print-toolbar">
      <span>正在使用「导出 PDF」打印视图。若未自动弹出打印对话框，请点右侧按钮，并在「目标打印机」中选择“另存为 PDF”。</span>
      <button type="button" onclick="window.print()">打印 / 另存为 PDF</button>
    </div>
  HTML

  PRINT_SCRIPT = <<~HTML
    <script>
      window.addEventListener('load', function () {
        setTimeout(function () { window.print(); }, 300);
      });
    </script>
  HTML

  def self.generate(task, report, print: false)
    # 统一转成字符串键的普通哈希再读（ReportGenerator 产出的符号键在此被规范化）
    data = JSON.parse(report.to_json)
    task_data = data['task'] || {}
    statistics = data['statistics'] || {}
    devices = data['devices'] || []
    errors = data['errors'] || []

    print_css = print ? PRINT_CSS : ''
    print_toolbar = print ? PRINT_TOOLBAR : ''
    print_script = print ? PRINT_SCRIPT : ''

    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <title>任务报告 - #{escape_html(task.name)}</title>
        <style>
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; background: #f5f7fa; padding: 24px; }
          .container { max-width: 1200px; margin: 0 auto; background: white; border-radius: 8px; box-shadow: 0 2px 12px rgba(0,0,0,0.1); padding: 32px; }
          h1 { font-size: 24px; color: #303133; margin-bottom: 8px; }
          h2 { font-size: 18px; color: #303133; margin: 24px 0 16px; padding-bottom: 8px; border-bottom: 2px solid #409eff; }
          .meta { color: #909399; font-size: 14px; margin-bottom: 24px; }
          .tag { display: inline-block; padding: 4px 12px; border-radius: 4px; font-size: 14px; margin-right: 8px; }
          .tag-success { background: #f0f9eb; color: #67c23a; }
          .tag-warning { background: #fdf6ec; color: #e6a23c; }
          .tag-danger { background: #fef0f0; color: #f56c6c; }
          .tag-info { background: #ecf5ff; color: #409eff; }
          .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 16px; margin-bottom: 24px; }
          .stat-card { background: #f5f7fa; padding: 16px; border-radius: 6px; text-align: center; }
          .stat-value { font-size: 28px; font-weight: bold; color: #303133; }
          .stat-label { font-size: 12px; color: #909399; margin-top: 4px; }
          .device-card { border: 1px solid #ebeef5; border-radius: 8px; margin-bottom: 16px; overflow: hidden; }
          .device-header { padding: 16px; background: #f5f7fa; display: flex; justify-content: space-between; align-items: center; }
          .device-title { font-weight: 600; color: #303133; }
          .device-meta { color: #909399; font-size: 14px; }
          table { width: 100%; border-collapse: collapse; }
          th, td { padding: 12px 16px; text-align: left; border-bottom: 1px solid #ebeef5; }
          th { background: #fafafa; font-weight: 600; color: #606266; font-size: 14px; }
          td { color: #606266; font-size: 14px; }
          .error-section { background: #fef0f0; border: 1px solid #fde2e2; border-radius: 8px; padding: 16px; margin-top: 24px; }
          .error-title { color: #f56c6c; font-weight: 600; margin-bottom: 12px; }
          .error-item { padding: 8px 0; border-bottom: 1px solid #fde2e2; }
          .error-item:last-child { border-bottom: none; }
          #{print_css}
        </style>
      </head>
      <body>
        #{print_toolbar}
        <div class="container">
          <h1>任务报告：#{escape_html(task.name)}</h1>
          <div class="meta">
            <span class="tag #{task_status_tag(task_data['status'])}">#{escape_html(task_data['status_text'])}</span>
            开始时间：#{format_time(task_data['started_at'])} |
            完成时间：#{format_time(task_data['completed_at'])} |
            耗时：#{escape_html(task_data['duration'] || '-')}
          </div>

          <h2>概览统计</h2>
          <div class="stats-grid">
            <div class="stat-card"><div class="stat-value">#{statistics['total_devices']}</div><div class="stat-label">总设备数</div></div>
            <div class="stat-card"><div class="stat-value" style="color:#67c23a">#{statistics['all_success_devices']}</div><div class="stat-label">全部成功</div></div>
            <div class="stat-card"><div class="stat-value" style="color:#e6a23c">#{statistics['partial_success_devices']}</div><div class="stat-label">部分成功</div></div>
            <div class="stat-card"><div class="stat-value" style="color:#f56c6c">#{statistics['all_failed_devices']}</div><div class="stat-label">全部失败</div></div>
            <div class="stat-card"><div class="stat-value">#{statistics['total_scripts']}</div><div class="stat-label">总脚本数</div></div>
            <div class="stat-card"><div class="stat-value">#{escape_html(statistics['script_success_rate'] || '0%')}</div><div class="stat-label">脚本成功率</div></div>
          </div>

          <h2>执行详情</h2>
          #{devices.map { |device| device_html(device) }.join}

          #{errors.empty? ? '' : errors_html(errors)}
        </div>
        #{print_script}
      </body>
      </html>
    HTML
  end

  def self.device_html(device)
    status = device['status']
    color = { 'completed' => '#67c23a', 'partial' => '#e6a23c', 'failed' => '#f56c6c' }[status] || '#909399'
    icon = { 'completed' => '✓', 'partial' => '!', 'failed' => '✗' }[status] || '○'
    scripts = device['scripts'] || []

    <<~HTML
      <div class="device-card">
        <div class="device-header">
          <div>
            <span class="device-title">[#{icon}] #{escape_html(device['name'])} (#{escape_html(device['device_ip'])}) - #{escape_html(device['device_model'] || '未知型号')}</span>
            <span class="device-meta" style="margin-left:12px;">[#{device['scripts_success']}/#{device['scripts_count']} 成功]</span>
            <span class="device-meta" style="margin-left:12px;">耗时: #{escape_html(device['duration'] || '-')}</span>
          </div>
          <span style="color:#{color};font-weight:500;">#{escape_html(device['status_text'])}</span>
        </div>
        <table>
          <thead>
            <tr>
              <th style="width:200px;">脚本名称</th>
              <th style="width:100px;">状态</th>
              <th style="width:100px;">耗时</th>
              <th>结论摘要</th>
              <th style="width:260px;">检查点结论</th>
            </tr>
          </thead>
          <tbody>
            #{scripts.map { |script| script_html(script) }.join}
          </tbody>
        </table>
      </div>
    HTML
  end

  def self.script_html(script)
    conclusion = case script['conclusion']
                 when 'success' then script['checkpoints_total'].to_i.positive? ? '检查点均通过' : nil
                 when 'partial' then '有检查点未通过'
                 when 'failure' then '检查点均未通过'
                 when 'error' then '脚本未执行完成'
                 else script['conclusion']
                 end

    <<~HTML
      <tr>
        <td>#{escape_html(script['name'])}</td>
        <td>#{escape_html(script['status_text'])}</td>
        <td>#{escape_html(script['duration'] || '-')}</td>
        <td>#{escape_html(script['error'] || conclusion || '-')}</td>
        <td>#{checkpoints_html(script)}</td>
      </tr>
    HTML
  end

  def self.checkpoints_html(script)
    checkpoints = script['checkpoints']
    return '-' unless checkpoints.is_a?(Array) && !checkpoints.empty?

    passed = script['checkpoints_passed'] || 0
    total = script['checkpoints_total'] || checkpoints.size
    summary_color = (script['checkpoints_failed'] || 0).positive? ? '#f56c6c' : '#67c23a'

    lines = checkpoints.map do |cp|
      mark = cp['passed'] == true ? '✓' : (cp['passed'] == false ? '✗' : '?')
      color = cp['passed'] == true ? '#67c23a' : (cp['passed'] == false ? '#f56c6c' : '#909399')
      text = "#{mark} #{cp['name']}"
      text += "（实际：#{cp['value']}）" unless cp['value'].nil? || cp['value'].to_s.empty?
      text += " — #{cp['reason']}" if cp['passed'] == false && cp['reason']
      %(<div style="color:#{color};font-size:13px;">#{escape_html(text)}</div>)
    end.join

    %(<div style="color:#{summary_color};font-weight:500;margin-bottom:2px;">#{passed}/#{total} 通过</div>#{lines})
  end

  def self.errors_html(errors)
    items = errors.map do |error|
      affected = (error['affected_devices'] || []).map { |d| "#{d['device_name']} (#{d['device_ip']}) - #{d['script_name']}" }.join('、')
      <<~HTML
        <div class="error-item">
          <div style="color:#f56c6c;font-weight:500;">#{escape_html(error['error'])}</div>
          <div style="color:#909399;font-size:13px;margin-top:4px;">影响 #{error['count']} 项：#{escape_html(affected)}</div>
        </div>
      HTML
    end.join

    %(<div class="error-section"><div class="error-title">错误汇总</div>#{items}</div>)
  end

  def self.task_status_tag(status)
    { 'completed' => 'tag-success', 'failed' => 'tag-danger' }[status] || 'tag-info'
  end

  def self.format_time(value)
    return '-' if value.blank?

    Time.parse(value.to_s).strftime('%Y-%m-%d %H:%M:%S')
  rescue StandardError
    value
  end

  def self.escape_html(str)
    return '' if str.nil?

    str.to_s.gsub(/[&<>"']/, '&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;')
  end
end
