// 脚本执行结果的公共渲染帮助（任务详情页与报告页共用）。
//
// 语义对齐本地客户端 views/task_detail.erb、views/task_report.erb 的内联逻辑：
//   - 检查点结论：一行一条，✓ 通过 / ✗ 失败 / ? 未判定，并给出"x/y 通过"摘要；
//   - 结论摘要：有 error 优先显示 error，否则给一句与"状态"列不同的说明；
//   - 状态文案与 Element Plus 标签类型映射。
//
// 用法：const SR = window.QingxunScriptResult; SR.formatCheckpoint(cp) ...
(function () {
  // ---- 状态 -> el-tag type ----
  function getStatusType(status) {
    return { pending: 'warning', running: 'primary', completed: 'success',
             failed: 'danger', cancelled: 'info' }[status] || 'info';
  }
  function getUnitStatusType(status) {
    return { completed: 'success', running: 'primary', failed: 'danger',
             pending: 'warning', assigned: 'info', cancelled: 'info' }[status] || 'info';
  }
  function getScriptStatusType(status) {
    return { completed: 'success', partial: 'warning', failed: 'danger',
             error: 'danger', running: 'primary', pending: 'warning' }[status] || 'info';
  }
  // 脚本状态中文（外层网元表的 status_text 由后端给，这里只有原始枚举时自己翻）
  function scriptStatusText(status) {
    return { completed: '成功', partial: '部分通过', failed: '失败', error: '执行异常',
             running: '执行中', pending: '待执行', cancelled: '已取消' }[status] || status || '待执行';
  }

  // ---- 检查点 ----
  function checkpointsOf(row) {
    return (row && Array.isArray(row.checkpoints)) ? row.checkpoints : [];
  }
  function failedCheckpointsOf(row) {
    return checkpointsOf(row).filter(function (cp) { return cp && cp.passed !== true; });
  }
  function passedCount(row) {
    return checkpointsOf(row).filter(function (cp) { return cp && cp.passed === true; }).length;
  }
  function failedCount(row) {
    return checkpointsOf(row).filter(function (cp) { return cp && cp.passed === false; }).length;
  }

  // 一行一条："✓/✗/?" + 名称（+ 实际值或失败原因）
  function formatCheckpoint(cp) {
    if (!cp) { return ''; }
    const mark = cp.passed === true ? '✓' : (cp.passed === false ? '✗' : '?');
    let text = mark + ' ' + (cp.name || '未命名检查点');
    if (cp.value !== null && cp.value !== undefined && cp.value !== '') { text += '（实际：' + cp.value + '）'; }
    if (cp.passed === false && cp.reason) { text += ' — ' + cp.reason; }
    return text;
  }

  function checkpointClass(cp) {
    if (!cp || cp.passed === null || cp.passed === undefined) { return 'is-unknown'; }
    return cp.passed ? 'is-passed' : 'is-failed';
  }

  // 结论摘要：有 error 优先；否则给一句与"状态"列不同的说明
  function formatConclusion(row) {
    if (!row) { return '-'; }
    if (row.error) { return row.error; }
    const texts = { success: '检查点均通过', partial: '有检查点未通过',
                    failure: '检查点均未通过', error: '脚本未执行完成' };
    const text = texts[row.conclusion];
    if (!text) { return row.conclusion || '-'; }
    if (row.conclusion === 'success' && checkpointsOf(row).length === 0) { return '-'; }
    return text;
  }

  window.QingxunScriptResult = {
    getStatusType: getStatusType,
    getUnitStatusType: getUnitStatusType,
    getScriptStatusType: getScriptStatusType,
    scriptStatusText: scriptStatusText,
    checkpointsOf: checkpointsOf,
    failedCheckpointsOf: failedCheckpointsOf,
    passedCount: passedCount,
    failedCount: failedCount,
    formatCheckpoint: formatCheckpoint,
    checkpointClass: checkpointClass,
    formatConclusion: formatConclusion
  };
})();
