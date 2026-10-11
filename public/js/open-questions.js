// 「待确认项」的可点击候选渲染（公共模块）。
//
// 契约（与后端 DescriptionDraftPayload / requirement_draft 提示词一致）：
//   描述正文里含【待确认#N】占位符；open_questions = [{ id, question, options }]。
//   点某个候选 -> 把【待确认#N】占位符整段替换成该候选文本（同一 id 出现多处时一次全换）；
//   改选时按"上一次填的值"替换（占位符已不存在），与「从手工日志生成」的行为一致。
//
// 用法：
//   const filler = QingxunOpenQuestions.createQuestionFiller({ previewEl, questionsEl, onAlert });
//   filler.render(open_questions);   // 渲染候选
(function () {
  function createQuestionFiller(options) {
    const opts = options || {};
    const previewEl = opts.previewEl;
    const questionsEl = opts.questionsEl;
    const onAlert = typeof opts.onAlert === 'function' ? opts.onAlert : function () {};
    const answers = {}; // id -> 已填入的文本

    function placeholder(id) {
      return '【待确认#' + id + '】';
    }

    // 把 id 的取值写进描述：先认占位符（可能有多个），再认上一次填的值（支持改选）
    function fill(id, text) {
      const value = String(text === null || text === undefined ? '' : text).trim();
      if (!value || !previewEl) { return false; }

      const ph = placeholder(id);
      let updated = previewEl.value;
      if (updated.indexOf(ph) !== -1) {
        updated = updated.split(ph).join(value);
      } else if (answers[id] && updated.indexOf(answers[id]) !== -1) {
        updated = updated.split(answers[id]).join(value);
      } else {
        onAlert('描述里已找不到 ' + ph + '（这段被手工改过）。请直接在描述里手动修改，或重新生成一次再选');
        return false;
      }

      previewEl.value = updated;
      previewEl.dispatchEvent(new Event('input', { bubbles: true }));
      answers[id] = value;
      return true;
    }

    // 渲染待确认列表：有候选就给可点击按钮；没有候选给输入框 + 「填入」
    function render(questions) {
      if (!questionsEl) { return; }
      questionsEl.innerHTML = '';
      const list = Array.isArray(questions) ? questions : [];
      if (list.length === 0) { return; }

      // 标题可选：调用方已有"待确认"标题时传 heading:null，避免重复
      if (opts.heading !== null) {
        const title = document.createElement('div');
        title.className = 'fw-medium mb-1';
        title.textContent = opts.heading || '待确认（点候选即填入描述）';
        questionsEl.appendChild(title);
      }

      list.forEach(function (q, index) {
        const id = (q && q.id !== undefined && q.id !== null) ? q.id : (index + 1);
        const wrap = document.createElement('div');
        wrap.className = 'mb-2';

        const question = document.createElement('div');
        question.textContent = placeholder(id) + ((q && q.question) ? (' ' + q.question) : '');
        wrap.appendChild(question);

        const choices = (q && Array.isArray(q.options)) ? q.options.slice() : [];
        if (choices.length > 0) {
          const group = document.createElement('div');
          group.className = 'd-flex flex-wrap gap-1 mt-1';
          choices.forEach(function (choice) {
            const button = document.createElement('button');
            button.type = 'button';
            button.className = 'btn btn-sm btn-outline-secondary';
            button.textContent = choice;
            button.addEventListener('click', function () {
              if (fill(id, choice)) {
                Array.prototype.forEach.call(group.querySelectorAll('button'), function (b) {
                  b.classList.remove('active');
                });
                button.classList.add('active');
              }
            });
            group.appendChild(button);
          });
          wrap.appendChild(group);
        } else {
          const input = document.createElement('input');
          input.className = 'form-control form-control-sm mt-1';
          input.placeholder = '填写这项的结论';
          const apply = document.createElement('button');
          apply.type = 'button';
          apply.className = 'btn btn-sm btn-outline-primary mt-1';
          apply.textContent = '填入';
          apply.addEventListener('click', function () {
            if (fill(id, input.value)) { input.value = ''; apply.textContent = '已填入'; }
          });
          wrap.appendChild(input);
          wrap.appendChild(apply);
        }

        questionsEl.appendChild(wrap);
      });
    }

    return { render: render, fill: fill };
  }

  window.QingxunOpenQuestions = { createQuestionFiller: createQuestionFiller };
})();
