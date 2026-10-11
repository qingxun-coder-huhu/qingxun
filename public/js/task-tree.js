// 任务「型号 → 设备 → 脚本」树选择器（编辑/新建任务页共用）。
//
// 用 Element Plus 原生级联（不设 check-strictly，默认即级联）：
//   勾选型号/设备 → 自动勾选全部后代；后代全勾时父级自动勾上；部分勾选显示半选。
//
// 为什么不用客户端那份手写级联：客户端在 @check 里改 default-checked-keys 的 ref，
// 而该 prop 只在 el-tree 挂载时读一次，之后再改不会生效 —— 也就是视觉上根本不级联，
// 默认态还容易只勾了子节点、漏了型号节点。这里统一为原生级联，两页共用一份，避免漂移。
(function () {
  const { ref, computed, nextTick } = Vue;

  function walk(nodes, fn) {
    (nodes || []).forEach((n) => { fn(n); if (n.children) walk(n.children, fn); });
  }

  // dataUrl: 取数地址（edit_data / new_data）
  // onLoaded(data): 拿到原始 JSON 的回调，供页面填基本信息
  function create(opts) {
    const dataUrl = opts.dataUrl;
    const onLoaded = opts.onLoaded || function () {};

    const treeData = ref([]);
    const taskTree = ref(null);
    const expandedKeys = ref([]);
    const checkedKeys = ref([]);   // 挂载时的默认勾选（default-checked-keys）
    const checkedIds = ref([]);    // 实时勾选 ∪ 半选，用于"已选择"计数
    const loadingTree = ref(true);
    const treeProps = { children: 'children', label: 'label', disabled: 'disabled' };

    const totalDeviceCount = computed(() => {
      let c = 0; walk(treeData.value, (n) => { if (n.type === 'device') c++; }); return c;
    });
    const selectedDeviceCount = computed(() => {
      let c = 0; walk(treeData.value, (n) => { if (n.type === 'device' && checkedIds.value.includes(n.id)) c++; }); return c;
    });

    const buildTree = (data) => {
      const devices = data.devices || [];
      const scripts = data.scripts || [];
      const selectedDevices = new Set((data.selected_device_ids || []).map(String));
      const selectedScripts = new Set((data.selected_script_ids || []).map(String));

      const groups = {};
      devices.forEach((d) => {
        const model = d.device_model || '未知型号';
        if (!groups[model]) { groups[model] = { id: 'model-' + model, label: model, type: 'model', children: [] }; }
        groups[model].children.push({
          id: 'device-' + d.id, deviceId: d.id, label: d.name, type: 'device',
          ip: d.ip_address, description: d.description,
          children: scripts.map((s) => ({
            id: 'script-' + d.id + '-' + s.id, deviceId: d.id, scriptId: s.id,
            label: s.name, type: 'script'
          }))
        });
      });
      treeData.value = Object.values(groups);

      // 默认勾选：叶子（脚本）按"是否属于已选脚本集合"，父级（设备/型号）自底向上推导 ——
      // 只有当某父级的子节点全部命中时父级才算勾选；子节点只命中一部分时交给 EP 显示半选。
      const leafSelected = (n) => selectedScripts.has(String(n.scriptId));
      const deviceSelected = (n) => selectedDevices.has(String(n.deviceId));
      const fullyChecked = (node) => {
        if (node.type === 'script') return leafSelected(node);
        if (node.type === 'device') return deviceSelected(node) && node.children.every(fullyChecked);
        return node.children.length > 0 && node.children.every(fullyChecked);
      };
      const checked = [];
      walk(treeData.value, (n) => { if (fullyChecked(n)) checked.push(n.id); });
      checkedKeys.value = checked;
      checkedIds.value = checked;

      // 默认全部展开（型号/设备/脚本都可见）
      const allIds = []; walk(treeData.value, (n) => allIds.push(n.id));
      expandedKeys.value = allIds;
    };

    const syncChecked = () => {
      if (!taskTree.value) return;
      checkedIds.value = taskTree.value.getCheckedKeys().concat(taskTree.value.getHalfCheckedKeys());
    };

    const applyChecked = (keys) => {
      if (!taskTree.value) return;
      taskTree.value.setCheckedKeys(keys);
      syncChecked();
    };

    const allNodeIds = () => { const ids = []; walk(treeData.value, (n) => ids.push(n.id)); return ids; };

    const load = async () => {
      loadingTree.value = true;
      try {
        const res = await fetch(dataUrl, { headers: { Accept: 'application/json' } });
        const data = await res.json();
        buildTree(data);
        onLoaded(data);
        await nextTick();
        syncChecked(); // 树挂载后回读真实勾选（含 EP 推导出的半选）
      } finally {
        loadingTree.value = false;
      }
    };

    const eachNode = (fn) => {
      const map = taskTree.value && taskTree.value.store && taskTree.value.store.nodesMap;
      if (map) { Object.values(map).forEach(fn); }
    };
    const expandAll = () => eachNode((n) => n.expand());
    const collapseAll = () => eachNode((n) => n.collapse());
    const checkAll = () => applyChecked(allNodeIds());
    const uncheckAll = () => applyChecked([]);
    const onCheck = () => syncChecked();

    // 保存载荷：设备 = 勾选 ∪ 半选节点里的设备；脚本 = 明确勾选的脚本叶子
    const payload = () => {
      const checked = new Set(taskTree.value ? taskTree.value.getCheckedKeys() : checkedIds.value);
      const half = new Set(taskTree.value ? taskTree.value.getHalfCheckedKeys() : []);
      const devSet = new Set([...checked, ...half]);
      const deviceIds = [];
      const scriptIds = new Set();
      walk(treeData.value, (n) => {
        if (n.type === 'device' && devSet.has(n.id)) deviceIds.push(n.deviceId);
        if (n.type === 'script' && checked.has(n.id)) scriptIds.add(n.scriptId);
      });
      return { device_ids: deviceIds, script_ids: Array.from(scriptIds) };
    };

    return {
      treeData, taskTree, expandedKeys, checkedKeys, checkedIds, loadingTree, treeProps,
      totalDeviceCount, selectedDeviceCount,
      load, buildTree, expandAll, collapseAll, checkAll, uncheckAll, onCheck, payload
    };
  }

  window.QingxunTaskTree = { create };
})();
