import { router, promptAction, window } from '@kit.ArkUI';
import { common, Configuration, ConfigurationConstant, EnvironmentCallback } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { injectWebStyles } from '../common/WebStyleInjector';
import { getStatusBarHeight } from '../common/WindowUtil';
import { PreferencesUtil } from '../common/PreferencesUtil';

/** 加载看门狗超时时间（毫秒）：超时未加载完成视为失败 */
const LOAD_TIMEOUT = 30000;
/** 会话 ID 合法格式（与看板/文件页一致） */
const SID_RE = /^session_[a-zA-Z0-9-]+$/;

/**
 * 全屏 Web 页：加载已保存的 Kimi 远程地址。
 * 交互方式（无任何常驻悬浮按钮，真正全屏）：
 * - 返回：系统侧滑手势，优先 Web 历史后退，无历史则退出应用；
 * - 刷新：在页面顶部下拉（Refresh 容器与 Web 联动）；
 * - 修改地址：双指双击屏幕，弹出操作面板。
 * 加载失败（主框架错误或超时）时显示原生错误页，可重试或修改地址。
 */
@Entry
@Component
struct WebPage {
  @State private serverUrl: string = '';
  @State private loading: boolean = false;
  @State private isRefreshing: boolean = false;
  @State private showMenu: boolean = false;
  @State private loadFailed: boolean = false;
  /** 推送 Token 获取失败的原因（用于界面提示排查） */
  @State private pushError: string = '';
  /** 状态栏高度（vp），内容层顶部显式避让 */
  @State private statusBarHeight: number = 0;
  /** 首次加载完成后，页内跳转不再显示全屏转圈 */
  private firstLoadDone: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  /** 最近一次应用到状态栏的背景色（去重，避免重复调用窗口 API） */
  private lastStatusColor: string = '';
  /** 页面是否正在离开（离开后不再设置状态栏颜色） */
  private leaving: boolean = false;
  /** 系统环境（深浅色）监听回调 ID，离开页面时移除 */
  private envCallbackId: number = 0;
  /** 加载态品牌图标跳动动画开关（onAppear 时开启，循环弹跳） */
  @State private iconJump: boolean = false;
  private loadTimer: number | null = null;
  // ---- Kimi RC（远程控制）支持 ----
  /** RC 模式：当前加载的是 code-rc.kimi.com 设备链接（登录需多窗口支持） */
  @State private rcMode: boolean = false;
  /** RC 登录弹窗 URL（非空时显示弹窗覆盖层，承载 window.open 的 OAuth 页） */
  @State private rcPopupUrl: string = '';
  /** RC 弹窗 WebView 的控制器 */
  private rcPopupController: webview.WebviewController = new webview.WebviewController();
  /** RC 地址输入弹层开关 */
  @State private showRcInput: boolean = false;
  /** RC 地址输入内容 */
  @State private rcUrl: string = '';

  async aboutToAppear(): Promise<void> {
    const ctx = getContext(this) as common.Context;
    // 监听系统深浅色切换，实时同步状态栏颜色（深色 #121212 / 浅色 #FFFFFF）
    try {
      const appCtx = ctx.getApplicationContext() as common.ApplicationContext;
      const envCallback: EnvironmentCallback = {
        onConfigurationUpdated: (config: Configuration): void => {
          if (this.leaving) {
            return;
          }
          const isDark = config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
          this.applyStatusBarColor(isDark ? '#121212' : '#FFFFFF');
        },
        onMemoryLevel: (): void => {
        }
      };
      this.envCallbackId = appCtx.on('environment', envCallback);
    } catch (e) {
      console.warn(`[Kimi] 注册深浅色监听失败: ${JSON.stringify(e)}`);
    }
    const url = await PreferencesUtil.getServerUrl(ctx);
    // 若无地址（理论上 Index 已分发，兜底处理），回输入页
    if (!url || url.length === 0) {
      router.replaceUrl({ url: 'pages/SetupPage' });
      return;
    }
    this.serverUrl = url;
    // 看板跳转：带 sessionId 参数时直接加载该会话页
    // 地址 = {base}/sessions/{sid}#token=xxx；base 优先取看板传入的 baseUrl（webBase 实时下发），
    // 兜底用已保存的访问地址；token 从已保存地址解析
    const params = router.getParams() as Record<string, string> | null;
    const sid = params?.sessionId ?? '';
    if (sid && SID_RE.test(sid)) {
      const hashIndex = url.indexOf('#');
      const savedBase = (hashIndex >= 0 ? url.substring(0, hashIndex) : url).replace(/\/+$/, '');
      const base = (params?.baseUrl && params.baseUrl.length > 0 ? params.baseUrl : savedBase).replace(/\/+$/, '');
      const m = url.match(/#token=([^&]+)/);
      const token = m ? m[1] : '';
      this.serverUrl = `${base}/sessions/${sid}${token ? '#token=' + token : ''}`;
      this.firstLoadDone = false;
    }
    // 地址就绪即进入加载动画态并启动看门狗：不等 onPageBegin（服务器不可达时
    // 主框架导航不会开始，onPageBegin 不触发，会一直停在 Web 的白色表面上）
    this.loading = true;
    this.startLoadWatchdog();
    // 读取状态栏高度，用于内容层顶部避让（网页面板等不能再被状态栏遮挡）
    this.statusBarHeight = await getStatusBarHeight(ctx);
    // 操作手势提示仅前两次进入时显示
    if (await PreferencesUtil.shouldShowHint(ctx)) {
      promptAction.showToast({ message: '下拉可刷新页面，双指捏合可修改地址', duration: 3000 });
    }
    // 初始化推送：请求通知授权 + 获取华为推送 Token（AGC 未配置时会失败，仅记录日志不影响使用）
    this.initPush(ctx as common.UIAbilityContext);
  }

  aboutToDisappear(): void {
    this.leaving = true;
    this.clearLoadWatchdog();
    this.unregisterStatusBridge();
    // 移除系统环境监听，避免组件销毁后回调残留
    if (this.envCallbackId !== 0) {
      try {
        (getContext(this).getApplicationContext() as common.ApplicationContext).off('environment', this.envCallbackId);
      } catch (e) {
        console.warn(`[Kimi] 移除深浅色监听失败: ${JSON.stringify(e)}`);
      }
      this.envCallbackId = 0;
    }
    // 离开 Web 页前恢复系统色，避免网页场景色残留到 SetupPage
    this.resetStatusBar();
  }

  /**
   * 设置状态栏背景色（文字颜色由 EntryAbility 统一按深浅色管理，避免重复设置）。
   */
  private applyStatusBarColor(hex: string): void {
    if (hex === this.lastStatusColor) {
      return; // 颜色未变，跳过
    }
    this.lastStatusColor = hex;
    window.getLastWindow(getContext(this) as common.Context)
      .then((win: window.Window) => {
        return win.setWindowSystemBarProperties({
          statusBarColor: hex,
        });
      })
      .catch((e: Error) => {
        console.warn(`[Kimi] 设置状态栏颜色失败: ${JSON.stringify(e)}`);
      });
  }

  /**
   * 按系统深浅色设置状态栏背景：深色 #121212 / 浅色 #FFFFFF，
   * 与网页顶部标题栏（跟随系统主题）保持一致。
   */
  private applySystemStatusBar(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const isDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.applyStatusBarColor(isDark ? '#121212' : '#FFFFFF');
  }

  /**
   * 恢复系统深浅色对应的状态栏颜色（与 EntryAbility 初始逻辑一致），
   * 用于非网页展示态（加载中、错误页、离开页面）。
   */
  private resetStatusBar(): void {
    this.lastStatusColor = '';
    this.applySystemStatusBar();
  }

  /**
   * 网页弹层遮罩联动：hex 非空时把状态栏设为遮罩在标题栏上的合成色（遮罩出现），
   * 为空时恢复系统深浅色（遮罩消失）。由注入的网页脚本通过 JS 桥调用（须保持 public 供 JS 代理访问）。
   */
  setOverlayColor(hex: string): void {
    if (this.leaving) {
      return;
    }
    if (!hex) {
      this.applySystemStatusBar();
    } else {
      this.applyStatusBarColor(hex);
    }
  }

  /** 注册网页到原生的状态栏桥，供网页脚本通过 window.kimiStatusBar 调用；须在页面加载前注册 */
  private registerStatusBridge(): void {
    try {
      this.controller.registerJavaScriptProxy(
        this,
        'kimiStatusBar',
        ['setOverlayColor']
      );
      console.info('[Kimi] 状态栏桥注册成功');
    } catch (e) {
      console.warn(`[Kimi] 状态栏桥注册失败: ${JSON.stringify(e)}`);
    }
  }

  /** 注销状态栏桥，避免页面销毁后残留 */
  private unregisterStatusBridge(): void {
    try {
      this.controller.deleteJavaScriptRegister('kimiStatusBar');
    } catch (e) {
      console.warn(`[Kimi] 状态栏桥注销失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 初始化推送：请求通知权限，获取 push token 并保存（供复制到 Mac 端配置）。
   */
  private async initPush(ctx: common.UIAbilityContext): Promise<void> {
    try {
      await notificationManager.requestEnableNotification(ctx);
    } catch (e) {
      console.warn(`[Kimi] 通知授权失败: ${JSON.stringify(e)}`);
    }
    try {
      const token = await pushService.getToken();
      await PreferencesUtil.savePushToken(ctx, token);
      this.pushError = '';
      console.info(`[Kimi] pushToken=${token}`);
    } catch (e) {
      this.pushError = JSON.stringify(e);
      console.warn(`[Kimi] 获取 pushToken 失败（检查 module.json5 的 client_id 配置）: ${JSON.stringify(e)}`);
    }
  }

  /** 复制推送 Token 到剪贴板 */
  private async copyPushToken(): Promise<void> {
    this.showMenu = false;
    const ctx = getContext(this) as common.Context;
    const token = await PreferencesUtil.getPushToken(ctx);
    if (!token) {
      const detail = this.pushError ? `：${this.pushError}` : '（尚未获取，请重新进入本页面试试）';
      promptAction.showToast({ message: `推送 Token 未就绪${detail}`, duration: 5000 });
      return;
    }
    const pb = pasteboard.getSystemPasteboard();
    pb.setDataSync(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, token));
    promptAction.showToast({ message: '推送 Token 已复制', duration: 2000 });
  }

  /** 发送一条本地测试通知（社交通信渠道，横幅弹出），验证通知权限与横幅/锁屏展示 */
  private async sendTestNotification(): Promise<void> {
    this.showMenu = false;
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        promptAction.showToast({ message: '通知权限未开启，请允许后重试', duration: 3000 });
        const ctx = getContext(this) as common.UIAbilityContext;
        await notificationManager.requestEnableNotification(ctx);
        return;
      }
      // 社交通信渠道对应 LEVEL_HIGH：横幅 + 提示音；发布时携带 slotType 会自动创建该渠道
      const request: notificationManager.NotificationRequest = {
        id: 1001,
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'KimiViewer 测试通知',
            text: '通知功能正常',
          },
        },
      };
      await notificationManager.publish(request);
      // 读取渠道实际级别用于诊断：4=横幅+提示音，3=仅提示音，2=仅状态栏图标，1=静默
      let slotInfo = '';
      try {
        const slot = await notificationManager.getSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
        const level = slot.notificationLevel !== undefined ? slot.notificationLevel : slot.level;
        slotInfo = `，渠道级别=${level}`;
      } catch (e) {
        slotInfo = `，读取渠道失败`;
      }
      promptAction.showToast({ message: `测试通知已发送${slotInfo}`, duration: 4000 });
    } catch (e) {
      promptAction.showToast({ message: `发送失败: ${JSON.stringify(e)}`, duration: 5000 });
    }
  }

  /**
   * 系统返回手势：优先 Web 历史后退，无历史则放行退出应用。
   */
  onBackPress(): boolean {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true; // 拦截
      }
    } catch (e) {
      console.warn(`[Kimi] onBackPress error: ${(e as Error).message}`);
    }
    return false; // 放行，退出应用
  }

  private refresh(): void {
    try {
      this.controller.refresh();
    } catch (e) {
      console.warn(`[Kimi] refresh error: ${(e as Error).message}`);
    }
  }

  /** 错误页"重试"：重新加载地址 */
  private retry(): void {
    this.loadFailed = false;
    this.loading = true;
    this.startLoadWatchdog();
    try {
      this.controller.loadUrl(this.serverUrl);
    } catch (e) {
      console.warn(`[Kimi] retry loadUrl error: ${(e as Error).message}`);
      this.loadFailed = true;
      this.loading = false;
    }
  }

  private goSetup(): void {
    this.showMenu = false;
    router.replaceUrl({ url: 'pages/SetupPage' });
  }

  /** 打开 Kimi RC 设备链接：校验后进入 RC 模式加载（多窗口登录支持） */
  private openRc(): void {
    const trimmed = this.rcUrl.trim();
    if (!/^https:\/\/code-rc\.kimi\.com\/devices\/[a-zA-Z0-9-]+\/?/.test(trimmed)) {
      promptAction.showToast({ message: '地址需为 https://code-rc.kimi.com/devices/ 开头的设备链接', duration: 3000 });
      return;
    }
    this.showRcInput = false;
    this.rcMode = true;
    this.loadFailed = false;
    this.firstLoadDone = false;
    this.loading = true;
    this.startLoadWatchdog();
    try {
      this.controller.loadUrl(trimmed);
    } catch (e) {
      console.warn(`[Kimi] openRc loadUrl error: ${(e as Error).message}`);
    }
  }

  /** 退出 RC 模式：回到已保存的 Kimi Web 地址 */
  private exitRc(): void {
    this.rcMode = false;
    this.rcPopupUrl = '';
    this.firstLoadDone = false;
    this.loading = true;
    this.startLoadWatchdog();
    try {
      this.controller.loadUrl(this.serverUrl);
    } catch (e) {
      console.warn(`[Kimi] exitRc loadUrl error: ${(e as Error).message}`);
    }
  }

  /** 加载看门狗：超时未完成则按失败处理，避免永久转圈 */
  private startLoadWatchdog(): void {
    this.clearLoadWatchdog();
    this.loadTimer = setTimeout(() => {
      if (!this.firstLoadDone && !this.loadFailed) {
        console.warn('[Kimi] 页面加载超时');
        this.loadFailed = true;
        this.loading = false;
        this.isRefreshing = false;
        // 超时进入错误页，状态栏恢复系统色
        this.resetStatusBar();
      }
    }, LOAD_TIMEOUT);
  }

  private clearLoadWatchdog(): void {
    if (this.loadTimer !== null) {
      clearTimeout(this.loadTimer);
      this.loadTimer = null;
    }
  }

  /**
   * 双指上滑检测：观察触摸事件但不消费（Transparent），不影响 Web 交互。
   * 两指按下后同步向上滑动超过 60px 触发菜单；横向位移过大（双指横向滚动/缩放）
   * 不触发，避免误触。
   */
  /**
   * 菜单手势：双指捏合（PinchGesture，见 Refresh 容器上的 parallelGesture）。
   * 历史包袱说明：TouchEvent 在双指移动时不透传（系统判定为捏合/缩放并拦截
   * Move 事件），因此早期基于 onTouchIntercept 的双指双击/双指上滑方案均不可靠，
   * 已改用原生手势 API。此方法保留用于打印触摸事件日志便于排查。
   */
  private onWebTouch = (event: TouchEvent): HitTestMode => {
    return HitTestMode.Transparent;
  }

  @Builder
  menuBuilder(): void {
    Column({ space: 12 }) {
      Text('当前地址')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'));
      Text(this.serverUrl)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');

      Button('刷新当前页')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor('#FFFFFF')
        .backgroundColor($r('app.color.accent_color'))
        .borderRadius(12)
        .margin({ top: 12 })
        .onClick(() => {
          this.showMenu = false;
          this.isRefreshing = true;
          this.refresh();
        });

      Button('修改访问地址')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.button_secondary_text'))
        .backgroundColor($r('app.color.button_secondary_bg'))
        .borderRadius(12)
        .onClick(() => {
          this.goSetup();
        });

      Button('浏览文件')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.button_secondary_text'))
        .backgroundColor($r('app.color.button_secondary_bg'))
        .borderRadius(12)
        .onClick(() => {
          this.showMenu = false;
          // 从网页当前地址提取会话 ID（/sessions/{sid}），供文件页锁定同一工作空间。
          // RC 模式下页面是 code-rc.kimi.com（URL 结构不同且不走本地 API），
          // 不提取，让文件页直接用兜底的最近会话（走 frp 链路 API）
          let target = 'pages/FilesPage';
          const params: Record<string, string> = {};
          if (!this.rcMode) {
            try {
              const url: string = this.controller.getUrl();
              const m = url.match(/\/sessions\/(session_[a-zA-Z0-9-]+)/);
              if (m) {
                params['sessionId'] = m[1];
              }
            } catch (e) {
              // getUrl 失败则不带参数（文件页会取最近会话兜底）
            }
          }
          router.pushUrl({ url: target, params: params });
        });

      Button('Kimi RC 远程')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.button_secondary_text'))
        .backgroundColor($r('app.color.button_secondary_bg'))
        .borderRadius(12)
        .onClick(() => {
          this.showMenu = false;
          this.showRcInput = true;
        });

      Button('复制推送 Token')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.button_secondary_text'))
        .backgroundColor($r('app.color.button_secondary_bg'))
        .borderRadius(12)
        .onClick(() => {
          this.copyPushToken();
        });

      Button('发送测试通知')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.button_secondary_text'))
        .backgroundColor($r('app.color.button_secondary_bg'))
        .borderRadius(12)
        .onClick(() => {
          this.sendTestNotification();
        });
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 });
  }

  @Builder
  errorBuilder(): void {
    Column({ space: 16 }) {
      Text('连接失败')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'));
      Text('无法连接到服务器，请检查网络或地址是否有效')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center);
      Text(this.serverUrl)
        .fontSize(12)
        .fontColor($r('app.color.text_placeholder'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('86%');

      Button('重试')
        .width('86%')
        .height(48)
        .fontSize(16)
        .fontColor('#FFFFFF')
        .backgroundColor($r('app.color.accent_color'))
        .borderRadius(12)
        .margin({ top: 16 })
        .onClick(() => {
          this.retry();
        });

      Button('修改访问地址')
        .width('86%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.button_secondary_text'))
        .backgroundColor($r('app.color.button_secondary_bg'))
        .borderRadius(12)
        .onClick(() => {
          this.goSetup();
        });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.web_status_bg'));
  }

  build(): void {
    Stack() {
      // 背景层：填满整屏（含状态栏与底部区域），颜色与 Kimi 网页背景一致，
      // 让状态栏区域与下方网页内容视觉上融为一体
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.web_status_bg'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);

      // 内容层：外层 Column 显式扩展全屏并用 padding 避开状态栏，确保网页面板不被遮挡
      Column() {
        Stack() {
          // 全屏 Web（地址就绪后才创建，避免以空地址初始化导致状态错乱）
          if (this.serverUrl.length > 0) {
            Refresh({ refreshing: $$this.isRefreshing }) {
          Web({ src: this.serverUrl, controller: this.controller })
            .width('100%')
            .height('100%')
            .mixedMode(MixedMode.All) // 允许 http 混合内容（适配局域网 http 地址）
            .darkMode(WebDarkMode.Auto) // 网页内容跟随系统深浅色模式
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .databaseAccess(false)
            .fileAccess(false)
            .geolocationAccess(false)
            .imageAccess(true)
            .multiWindowAccess(true) // Kimi RC 登录用 window.open 弹 OAuth 窗口，需多窗口支持
            .keyboardAvoidMode(WebKeyboardAvoidMode.RESIZE_CONTENT)
            .onControllerAttached(() => {
              // controller 与 Web 组件关联后、页面加载前注册 JS 桥，
              // 这样页面加载完成后网页脚本才能访问 window.kimiStatusBar
              this.registerStatusBridge();
            })
            .onWindowNew((event: OnWindowNewEvent) => {
              // window.open 弹窗请求（RC 登录 OAuth）：绑定弹窗 WebView 的 controller
              // 并在覆盖层显示，让 OAuth 流程在 APP 内完成。
              // 注意：登录页用 window.open() 无参调用（targetUrl 为空，先开窗后写内容），
              // 此时弹窗加载 about:blank，OAuth 内容由页面脚本随后写入
              console.info(`[Kimi][rc] onWindowNew: '${event.targetUrl}'`);
              this.rcPopupUrl = event.targetUrl && event.targetUrl.length > 0
                ? event.targetUrl : 'about:blank';
              try {
                event.handler.setWebController(this.rcPopupController);
              } catch (e) {
                console.warn(`[Kimi][rc] setWebController 失败: ${(e as Error).message}`);
              }
            })
            .onWindowExit(() => {
              // OAuth 弹窗关闭：回到主 WebView（登录态 Cookie 已在共享 CookieStore）
              console.info('[Kimi][rc] 弹窗已关闭');
              this.rcPopupUrl = '';
            })
            .onRenderExited((event: OnRenderExitedEvent) => {
              // 渲染进程异常退出（崩溃/OOM 等）：提示并自动重载恢复
              console.error(`[Kimi] 渲染进程退出 reason=${event.renderExitReason}`);
              promptAction.showToast({ message: '页面异常，正在重新加载…', duration: 2000 });
              this.retry();
            })
            .onPageBegin(() => {
              // 新导航开始，清除错误态；仅首次加载显示全屏转圈，页内跳转不打扰
              this.loadFailed = false;
              // 新页面加载中，状态栏恢复系统色，加载完成后切到网页场景色
              this.resetStatusBar();
              if (!this.firstLoadDone) {
                this.loading = true;
              }
              this.startLoadWatchdog();
            })
            .onPageEnd(() => {
              // 注意：加载失败后系统也会回调 onPageEnd（加载内置错误页），
              // 这里不能清除 loadFailed，否则错误页会一闪而过
              this.clearLoadWatchdog();
              this.loading = false;
              this.isRefreshing = false;
              this.firstLoadDone = true;
              injectWebStyles(this.controller);
              // 页面加载完成：状态栏按系统深浅色设置（与网页顶部标题栏同色系）
              if (!this.loadFailed) {
                this.applySystemStatusBar();
              }
            })
            .onErrorReceive((event: OnErrorReceiveEvent) => {
              // 仅主框架加载失败才显示错误页，子资源失败不影响
              if (event && event.request.isMainFrame()) {
                console.error(`[Kimi] 页面加载错误: ${event.error.getErrorCode()} ${event.error.getErrorInfo()}`);
                this.clearLoadWatchdog();
                this.loadFailed = true;
                this.loading = false;
                this.isRefreshing = false;
                // 错误页背景为系统色，状态栏一并恢复，避免残留网页场景色
                this.resetStatusBar();
              }
            });
        }
        .width('100%')
        .height('100%')
        .onRefreshing(() => {
          this.refresh();
        })
        .parallelGesture(PinchGesture({ fingers: 2 })
          .onActionEnd((event: GestureEvent) => {
            // 双指捏合（张开或收紧均可）结束即弹出菜单；
            // 原生手势系统检测，不依赖 TouchEvent 透传（后者收不到双指 Move）
            console.info(`[Kimi][pinch] scale=${event.scale}`);
            this.showMenu = true;
          }));
          }

      // 首次加载态：品牌启动动画（Kimi 工作图标循环跳动，背景跟随深浅色），替代白色转圈
      if (this.loading) {
        Column() {
          Image($r('app.media.working_icon'))
            .width(132)
            .height(132)
            .translate({ y: this.iconJump ? -22 : 0 })
            .animation({
              duration: 460,
              curve: Curve.EaseInOut,
              iterations: -1,
              playMode: PlayMode.Alternate,
            })
            .onAppear(() => {
              // 组件出现后开启跳动动画，直到页面加载完成组件移除
              this.iconJump = true;
            })
            .onDisAppear(() => {
              this.iconJump = false;
            });
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.web_status_bg'))
        .transition(TransitionEffect.OPACITY.animation({ duration: 260 }))
        .hitTestBehavior(HitTestMode.Transparent);
      }

      // 加载失败错误页（覆盖在 Web 之上）
          if (this.loadFailed) {
            this.errorBuilder();
          }

      // RC 模式提示条（顶部横幅，点击退出）
      if (this.rcMode) {
        Row() {
          Text('Kimi RC 模式')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .backgroundColor($r('app.color.accent_color'))
            .borderRadius(8)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 });
          Blank();
          Text('退出')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .padding(6)
            .onClick(() => {
              this.exitRc();
            });
        }
        .width('100%')
        .padding({ left: 12, right: 12 })
        .backgroundColor($r('app.color.sheet_bg'))
        .position({ x: 0, y: 0 });
      }

      // RC OAuth 弹窗覆盖层（最上层）
      this.rcPopupOverlay();
        }
        .width('100%')
        .layoutWeight(1);
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.statusBarHeight })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      // RC 输入弹层挂在内层容器（同一节点挂两个 bindSheet 会相互冲突，后者使前者失效）
      .bindSheet($$this.showRcInput, this.rcInputBuilder(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        backgroundColor: $r('app.color.sheet_bg'),
        title: { title: 'Kimi RC 远程' },
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.web_status_bg'))
    .onTouchIntercept(this.onWebTouch)
    .bindSheet($$this.showMenu, this.menuBuilder(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.sheet_bg'),
      title: { title: '操作' },
    });
  }

  /** RC 设备链接输入弹层 */
  @Builder
  rcInputBuilder(): void {
    Column({ space: 12 }) {
      Text('粘贴 kimi rc 生成的设备链接（https://code-rc.kimi.com/devices/…），登录认证将在 APP 内完成。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      TextInput({ text: this.rcUrl, placeholder: 'https://code-rc.kimi.com/devices/…' })
        .width('100%')
        .height(52)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_placeholder'))
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .onChange((v: string) => {
          this.rcUrl = v;
        });
      Button('打开')
        .width('100%')
        .height(46)
        .fontSize(16)
        .fontColor('#FFFFFF')
        .backgroundColor($r('app.color.accent_color'))
        .borderRadius(12)
        .onClick(() => {
          this.openRc();
        });
      if (this.rcMode) {
        Button('退出 RC，返回 Kimi Web')
          .width('100%')
          .height(46)
          .fontSize(15)
          .fontColor($r('app.color.button_secondary_text'))
          .backgroundColor($r('app.color.button_secondary_bg'))
          .borderRadius(12)
          .onClick(() => {
            this.showRcInput = false;
            this.exitRc();
          });
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 });
  }

  /** RC OAuth 弹窗覆盖层（承载 window.open 的登录窗口） */
  @Builder
  rcPopupOverlay(): void {
    if (this.rcPopupUrl.length > 0) {
      Column() {
        // 顶栏：标题 + 完成按钮
        Row() {
          Text('登录')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .padding({ left: 16 });
          Text('完成')
            .fontSize(15)
            .fontColor($r('app.color.accent_color'))
            .width(64)
            .height(44)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              // 手动关闭弹窗（OAuth 完成后点击）
              this.rcPopupUrl = '';
            });
        }
        .width('100%')
        .height(50);
        // 弹窗 WebView（controller 已在 onWindowNew 中绑定给系统）
        Web({ src: this.rcPopupUrl, controller: this.rcPopupController })
          .width('100%')
          .layoutWeight(1)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .darkMode(WebDarkMode.Auto)
          .multiWindowAccess(false);
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.web_status_bg'))
      .padding({ top: this.statusBarHeight })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
  }
}
