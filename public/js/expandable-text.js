// 「最多 N 行 + 展开/收起」的折叠容器（默认 4 行）。
//
// 用途：结论、检查点结论这类内容的长度不可控，全铺开会把表格撑得很高 —— 一个脚本记了
// 十几条检查点时尤其明显，整个报告页都是被这一个列顶开的。默认只看几行，想细看再展开。
//
// 隐性知识：
//   1. 用 max-height 裁，而不是 -webkit-line-clamp。检查点那块是**多个块级子元素**
//      （每条一行、按通过/失败着色），而 line-clamp 只裁文本行、对块级子元素不生效。
//   2. 折起来的边界要落在整行上，所以 body 固定 line-height: 1.6，并要求子元素字号一致
//      （字号不同的行高不同，max-height 会切出半行）。给 body 单独设 font-size 的地方
//      就是为此（见 task_report.erb 里检查点那条规则）。
//   3. 只有真的被裁掉才显示"展开"：要量 scrollHeight，光看字符数猜不准（同样的字符数
//      在窄列里可能折成 6 行、宽列里 3 行）。
(function () {
  const { ref, onMounted, onUpdated, watch, nextTick } = Vue;

  window.ExpandableText = {
    name: 'ExpandableText',
    props: {
      lines: { type: Number, default: 4 }
    },
    setup() {
      const expanded = ref(false);
      const body = ref(null);
      const overflow = ref(false);

      // 只在收起态量：展开态没有 max-height 限制，scrollHeight 与 clientHeight 相等，
      // 量出来永远是"没超出"，反而会把"收起"链接弄没。
      const measure = () => {
        const el = body.value;
        if (!el || expanded.value) return;
        overflow.value = el.scrollHeight > el.clientHeight + 1;
      };

      onMounted(() => nextTick(measure));
      onUpdated(() => nextTick(measure)); // 报告页会自动刷新，内容变了要重新量
      watch(expanded, () => nextTick(measure));

      return { expanded, body, overflow };
    },
    template: `
      <div class="expandable-text">
        <div
          ref="body"
          class="expandable-text__body"
          :class="{ 'is-clamped': !expanded }"
          :style="{ '--clamp-lines': lines }"
        >
          <slot></slot>
        </div>
        <a v-if="overflow" class="expandable-text__toggle" @click="expanded = !expanded">
          {{ expanded ? '收起' : '展开' }}
        </a>
      </div>
    `
  };
})();
