import { webview } from '@kit.ArkWeb';

const STYLE_ID = 'kimi-web-style';

/**
 * 注入网页的样式修复：
 * 1. 会话页标题栏背景与状态栏保持一致（深色 #121212 / 浅色 #FFFFFF，去掉毛玻璃色差）；
 * 2. 文件/会话面板的顶部边框去掉。
 */
const WEB_STYLE_CSS: string = [
  // 标题栏：浅色模式固定白底，深色模式固定 #121212，与状态栏颜色一致
  '.topbar {',
  '  background-color: #FFFFFF !important;',
  '  backdrop-filter: none !important;',
  '  -webkit-backdrop-filter: none !important;',
  '}',
  '@media (prefers-color-scheme: dark) {',
  '  .topbar {',
  '    background-color: #121212 !important;',
  '  }',
  '}',
  // 文件/会话面板：去掉顶部边框
  '.panel-tab-bar {',
  '  border: none !important;',
  '}',
  '.sheet-panel {',
  '  border-top: none !important;',
  '}',
  // 移动端全屏文件面板：去掉顶部边框（border-top 与状态栏之间的一条线）
  '.global-preview.mobile {',
  '  border-top: none !important;',
  '}',
  // 弹层遮罩：禁用淡入淡出过渡，遮罩瞬间出现/消失，与状态栏同帧切换（避免闪烁）
  '.sheet-enter-active, .sheet-leave-active {',
  '  transition: opacity 0s !important;',
  '}',
  // 去掉点击后按钮等元素出现的蓝色焦点方框
  // 1. 移动端点击高亮（tap highlight）：点击瞬间出现的蓝色半透明方框
  '* {',
  '  -webkit-tap-highlight-color: transparent !important;',
  '}',
  // 2. 焦点环（focus ring / outline / 蓝色光晕），含 focus-within（点击输入卡片等容器）
  '*:focus,',
  '*:focus-visible,',
  '*:focus-within {',
  '  outline: none !important;',
  '  box-shadow: none !important;',
  '}',
  // 3. 输入卡片/搜索框聚焦时的蓝色描边（border 伪元素）
  '.composer-card:focus-within:after,',
  '.tsearch:focus-within:after {',
  '  border-color: transparent !important;',
  '  opacity: 0 !important;',
  '}',
  // 4. 底部输入框（composer-card）圆角改为 16px（原 32px）
  '.composer-card {',
  '  border-radius: 16px !important;',
  '  corner-shape: round !important;',
  '}',
].join('\n');

/**
 * 注入脚本保持幂等：整页刷新后重新注入；SPA 内路由变化由 MutationObserver 负责恢复。
 */
const INJECT_SCRIPT: string = `
(() => {
  const STYLE_ID = ${JSON.stringify(STYLE_ID)};
  const cssText = ${JSON.stringify(WEB_STYLE_CSS)};

  function ensureStyle() {
    let style = document.getElementById(STYLE_ID);
    if (!style) {
      style = document.createElement('style');
      style.id = STYLE_ID;
      document.head.appendChild(style);
    }
    if (style.textContent !== cssText) {
      style.textContent = cssText;
    }
  }

  function enhance() {
    try {
      ensureStyle();
    } catch (error) {
      // 注入失败静默，下次 DOM 变化重试
    }
  }

  // ---- 弹层遮罩联动：遮罩出现/消失时实时同步状态栏颜色；
  //     动画过渡期间逐帧跟随遮罩透明度，保证状态栏与遮罩同帧切换 ----
  const SCRIM_SELECTOR = '.sheet-scrim, .ui-dialog__overlay, .drop-overlay, .html-preview-frame__backdrop, .mermaid-modal-overlay, .infographic-modal-overlay';
  let lastOverlayColor = '';

  function parseCssColor(c) {
    if (!c) {
      return null;
    }
    const nums = c.match(/[0-9.]+/g);
    if (!nums || nums.length < 3) {
      return null;
    }
    let r = parseFloat(nums[0]);
    let g = parseFloat(nums[1]);
    let b = parseFloat(nums[2]);
    const a = nums.length > 3 ? parseFloat(nums[3]) : 1;
    // color(srgb r g b / a) 等新格式的值为 0-1 浮点，转成 0-255
    if (c.indexOf('srgb') >= 0) {
      r *= 255;
      g *= 255;
      b *= 255;
    }
    return { r: r, g: g, b: b, a: a };
  }

  function toHex(n) {
    const h = Math.round(n).toString(16);
    return h.length < 2 ? '0' + h : h;
  }

  function findVisibleScrim() {
    const els = document.querySelectorAll(SCRIM_SELECTOR);
    for (let i = 0; i < els.length; i++) {
      const el = els[i];
      if (el.getClientRects().length === 0) {
        continue;
      }
      const st = getComputedStyle(el);
      if (st.display === 'none' || st.visibility === 'hidden') {
        continue;
      }
      return el;
    }
    return null;
  }

  function computeOverlayHex(scrim) {
    const top = document.querySelector('.topbar');
    const topBg = top ? getComputedStyle(top).backgroundColor : null;
    const t = parseCssColor(topBg);
    const s = parseCssColor(getComputedStyle(scrim).backgroundColor);
    if (!t || !s) {
      return '';
    }
    // 遮罩淡入/淡出动画的 opacity 作用在祖先（如 .sheet-root）上，需沿祖先链累乘透明度
    let a = s.a;
    let el = scrim;
    while (el && el.parentElement) {
      const o = parseFloat(getComputedStyle(el).opacity || '1');
      if (!isNaN(o)) {
        a *= o;
      }
      el = el.parentElement;
    }
    return '#' + toHex(t.r * (1 - a) + s.r * a) + toHex(t.g * (1 - a) + s.g * a) + toHex(t.b * (1 - a) + s.b * a);
  }

  function pushOverlayColor(hex) {
    if (hex === lastOverlayColor) {
      return;
    }
    lastOverlayColor = hex;
    const bridge = window.kimiStatusBar;
    if (bridge && typeof bridge.setOverlayColor === 'function') {
      try {
        bridge.setOverlayColor(hex);
      } catch (e) {
        // 页面重载期间桥可能尚未就绪，忽略
      }
    }
  }

  function blendOverlayColor() {
    // 快速判断：DOM 中无遮罩类元素时直接恢复系统色（避免每次全量样式计算）
    if (!document.querySelector(SCRIM_SELECTOR)) {
      pushOverlayColor('');
      return;
    }
    const scrim = findVisibleScrim();
    if (scrim) {
      // 遮罩出现：立即切换到最终合成色（遮罩动画已禁用，二者同帧到位）
      pushOverlayColor(computeOverlayHex(scrim));
    } else {
      // 遮罩消失：恢复系统深浅色
      pushOverlayColor('');
    }
  }

  // ---- 图片附件缩略图 / 用户消息排版相关注入已撤销，恢复 Kimi Web 原生附件展示 ----

  enhance();
  blendOverlayColor();
  if (window.kimiWebStyleObserver) {
    window.kimiWebStyleObserver.disconnect();
  }
  let scheduled = false;
  window.kimiWebStyleObserver = new MutationObserver(() => {
    if (scheduled) {
      return;
    }
    scheduled = true;
    window.requestAnimationFrame(() => {
      scheduled = false;
      enhance();
      blendOverlayColor();
    });
  });
  window.kimiWebStyleObserver.observe(document.documentElement, {
    childList: true,
    subtree: true,
    // 监听 class 变化，捕获 Vue 过渡的 enter/leave-active 类切换（遮罩淡入淡出动画）
    attributes: true,
    attributeFilter: ['class']
  });

  return JSON.stringify({
    styleInserted: !!document.getElementById(STYLE_ID),
    url: location.href
  });
})();
`;

/** 向当前网页注入样式修复脚本。 */
export function injectWebStyles(controller: webview.WebviewController): void {
  controller.runJavaScript(INJECT_SCRIPT)
    .then((result: string) => {
      console.info(`[Kimi] 网页样式注入结果: ${result}`);
    })
    .catch((error: Error) => {
      console.warn(`[Kimi] 注入网页样式失败: ${error.message}`);
    });
}
