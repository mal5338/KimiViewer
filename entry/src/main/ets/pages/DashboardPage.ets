import { router, promptAction, window } from '@kit.ArkUI';
import { common, Configuration, ConfigurationConstant, EnvironmentCallback } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { getStatusBarHeight } from '../common/WindowUtil';
import { PreferencesUtil } from '../common/PreferencesUtil';

/** 加载看门狗超时时间（毫秒） */
const LOAD_TIMEOUT = 30000;
/** 会话 ID 合法格式（防注入，与 kimi web 会话页 URL 对齐） */
const SID_RE = /^session_[a-zA-Z0-9-]+$/;

/**
 * 会话看板页（启动默认页）：全屏 WebView 加载 kimi-dashboard。
 * - 单击卡片：网页通过 JS 桥 kimiNative.openSession(sid) 通知原生，
 *   跳转 WebPage 加载 {kimi-web-base}/sessions/{sid}；
 * - 修改看板地址：双指捏合菜单；
 * - 返回：系统侧滑，优先 Web 历史后退，无历史则退出应用。
 */
@Entry
@Component
struct DashboardPage {
  @State private boardUrl: string = '';
  @State private loading: boolean = false;
  @State private isRefreshing: boolean = false;
  @State private showMenu: boolean = false;
  @State private loadFailed: boolean = false;
  @State private statusBarHeight: number = 0;
  /** 看板地址输入弹层 */
  @State private showBoardInput: boolean = false;
  @State private boardUrlInput: string = '';
  /** 首次加载完成后不再显示全屏转圈 */
  private firstLoadDone: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private lastStatusColor: string = '';
  private leaving: boolean = false;
  private envCallbackId: number = 0;
  @State private iconJump: boolean = false;
  private loadTimer: number | null = null;

  async aboutToAppear(): Promise<void> {
    const ctx = getContext(this) as common.Context;
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
    this.boardUrl = await PreferencesUtil.getDashboardUrl(ctx);
    this.loading = true;
    this.startLoadWatchdog();
    this.statusBarHeight = await getStatusBarHeight(ctx);
    if (await PreferencesUtil.shouldShowHint(ctx)) {
      promptAction.showToast({ message: '单击卡片进入会话，长按卡片查看详情', duration: 3000 });
    }
  }

  aboutToDisappear(): void {
    this.leaving = true;
    this.clearLoadWatchdog();
    this.unregisterBridge();
    if (this.envCallbackId !== 0) {
      try {
        (getContext(this).getApplicationContext() as common.ApplicationContext).off('environment', this.envCallbackId);
      } catch (e) {
        console.warn(`[Kimi] 移除深浅色监听失败: ${JSON.stringify(e)}`);
      }
      this.envCallbackId = 0;
    }
    this.resetStatusBar();
  }

  private applyStatusBarColor(hex: string): void {
    if (hex === this.lastStatusColor) {
      return;
    }
    this.lastStatusColor = hex;
    window.getLastWindow(getContext(this) as common.Context)
      .then((win: window.Window) => {
        return win.setWindowSystemBarProperties({ statusBarColor: hex });
      })
      .catch((e: Error) => {
        console.warn(`[Kimi] 设置状态栏颜色失败: ${JSON.stringify(e)}`);
      });
  }

  private applySystemStatusBar(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const isDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.applyStatusBarColor(isDark ? '#121212' : '#FFFFFF');
  }

  private resetStatusBar(): void {
    this.lastStatusColor = '';
    this.applySystemStatusBar();
  }

  /** 注册看板 → 原生的会话跳转桥（须在页面加载前注册） */
  private registerBridge(): void {
    try {
      this.controller.registerJavaScriptProxy(this, 'kimiNative', ['openSession', 'downloadFile']);
      console.info('[Kimi] 看板桥注册成功');
    } catch (e) {
      console.warn(`[Kimi] 看板桥注册失败: ${JSON.stringify(e)}`);
    }
  }

  private unregisterBridge(): void {
    try {
      this.controller.deleteJavaScriptRegister('kimiNative');
    } catch (e) {
      console.warn(`[Kimi] 看板桥注销失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 网页卡片单击回调（JS 桥，须保持 public）：接收完整会话 URL（webBase 由看板后端下发，
   * 避免依赖 APP 内可能过期的已存地址），校验后跳转会话页。
   */
  openSession(target: string): void {
    const m = /^https?:\/\/[^\s#]+\/sessions\/(session_[a-zA-Z0-9-]+)$/.exec(target || '');
    if (!m) {
      console.warn(`[Kimi] openSession 非法参数: ${target}`);
      return;
    }
    const sid = m[1];
    const base = target.substring(0, target.indexOf('/sessions/'));
    try {
      router.pushUrl({ url: 'pages/WebPage', params: { sessionId: sid, baseUrl: base } });
    } catch (e) {
      console.warn(`[Kimi] openSession 跳转失败: ${(e as Error).message}`);
      promptAction.showToast({ message: '打开会话失败', duration: 2000 });
    }
  }

  /**
   * 网页下载回调（JS 桥，须保持 public）：request.agent 托管下载到临时文件后弹系统保存对话框。
   * 框架负责写盘（此前 requestInStream + dataReceive 真机 0 KB），流式落盘无 OOM 风险。
   * 令牌由网页拼在 URL query（k=），这里不做鉴权处理。
   */
  async downloadFile(target: string, fileName?: string): Promise<void> {
    if (!/^https?:\/\/\S+$/i.test(target || '')) {
      console.warn(`[Kimi] downloadFile 非法参数: ${target}`);
      promptAction.showToast({ message: '下载地址无效', duration: 2000 });
      return;
    }
    promptAction.showToast({ message: '正在下载…', duration: 2000 });
    const ctx = getContext(this) as common.Context;
    // 文件名：优先网页传入；否则从 URL 的 path 参数解析（/kd/file/raw?path=xx）
    let name = '';
    const given = (fileName || '').trim();
    if (given) {
      name = given.split('/').pop() || '';
    } else {
      const m = /[?&]path=([^&]+)/.exec(target || '');
      if (m) {
        try {
          name = decodeURIComponent(m[1]).split('/').pop() || '';
        } catch (e) {
          name = '';
        }
      }
      if (!name) {
        name = decodeURIComponent(target.split('?')[0].split('#')[0].split('/').pop() || 'file');
      }
    }
    const tmpPath = `${ctx.cacheDir}/kd_dl_${Date.now()}_${name}`;
    try {
      const cfg: request.agent.Config = {
        action: request.agent.Action.DOWNLOAD,
        url: target,
        mode: request.agent.Mode.FOREGROUND,
        overwrite: true,
        saveas: tmpPath
      };
      const task = await request.agent.create(ctx, cfg);
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('下载超时')), 300000);
        task.on('completed', () => {
          clearTimeout(timer);
          resolve();
        });
        task.on('failed', (p: request.agent.Progress) => {
          clearTimeout(timer);
          reject(new Error(`task ${p.state}`));
        });
        task.start();
      });
      // 下载完成后文件已落盘；任务记录交给系统自动过期清理
      if (fileIo.statSync(tmpPath).size === 0) {
        throw new Error('empty file');
      }
    } catch (e) {
      console.error(`[Kimi] downloadFile 下载失败: ${(e as Error).message}`);
      promptAction.showToast({ message: '下载失败', duration: 2000 });
      try {
        fileIo.unlinkSync(tmpPath);
      } catch (err) { /* 临时文件可能尚未创建 */ }
      return;
    }
    try {
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [name];
      const docPicker = new picker.DocumentViewPicker();
      const uris = await docPicker.save(opts);
      if (!uris || uris.length === 0) {
        return; // 用户取消保存
      }
      const dst = fileIo.openSync(uris[0],
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        await fileIo.copyFile(tmpPath, dst.fd);   // 异步拷贝必须等待，否则 closeSync 先关 fd 导致 0 KB
      } finally {
        fileIo.closeSync(dst);
      }
      promptAction.showToast({ message: `已保存 ${name}`, duration: 2500 });
    } catch (e) {
      console.error(`[Kimi] downloadFile 保存失败: ${(e as Error).message}`);
      promptAction.showToast({ message: '保存失败', duration: 2000 });
    } finally {
      try {
        fileIo.unlinkSync(tmpPath);
      } catch (err) { /* 清理临时文件失败可忽略 */ }
    }
  }

  // 离开/返回看板页时暂停/恢复看板推流，把带宽让给会话页加载
  onPageShow(): void {
    try {
      this.controller.runJavaScript("window.__kdSsePause && window.__kdSsePause(false)");
    } catch (e) { /* 忽略：页面可能尚未就绪 */ }
  }

  onPageHide(): void {
    try {
      this.controller.runJavaScript("window.__kdSsePause && window.__kdSsePause(true)");
    } catch (e) { /* 忽略 */ }
  }

  onBackPress(): boolean {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (e) {
      console.warn(`[Kimi] onBackPress error: ${(e as Error).message}`);
    }
    return false;
  }

  private refresh(): void {
    try {
      this.controller.refresh();
    } catch (e) {
      console.warn(`[Kimi] refresh error: ${(e as Error).message}`);
    }
  }

  private retry(): void {
    this.loadFailed = false;
    this.loading = true;
    this.startLoadWatchdog();
    try {
      this.controller.loadUrl(this.boardUrl);
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

  /** 保存看板地址并重载 */
  private async saveBoardUrl(): Promise<void> {
    const trimmed = this.boardUrlInput.trim();
    if (!/^https?:\/\/.+/i.test(trimmed)) {
      promptAction.showToast({ message: '地址需以 http:// 或 https:// 开头', duration: 2500 });
      return;
    }
    const ctx = getContext(this) as common.Context;
    await PreferencesUtil.saveDashboardUrl(ctx, trimmed);
    this.showBoardInput = false;
    this.showMenu = false;
    this.boardUrl = trimmed;
    this.firstLoadDone = false;
    this.loadFailed = false;
    this.loading = true;
    this.startLoadWatchdog();
    try {
      this.controller.loadUrl(trimmed);
    } catch (e) {
      console.warn(`[Kimi] 保存看板地址后加载失败: ${(e as Error).message}`);
    }
  }

  private startLoadWatchdog(): void {
    this.clearLoadWatchdog();
    this.loadTimer = setTimeout(() => {
      if (!this.firstLoadDone && !this.loadFailed) {
        console.warn('[Kimi] 看板加载超时');
        this.loadFailed = true;
        this.loading = false;
        this.isRefreshing = false;
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

  @Builder
  menuBuilder(): void {
    Column({ space: 12 }) {
      Text('当前看板地址')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'));
      Text(this.boardUrl)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');

      Button('刷新看板')
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

      Button('修改看板地址')
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.button_secondary_text'))
        .backgroundColor($r('app.color.button_secondary_bg'))
        .borderRadius(12)
        .onClick(() => {
          this.showMenu = false;
          this.boardUrlInput = this.boardUrl;
          this.showBoardInput = true;
        });

      Button('修改 Kimi 访问地址')
        .width('100%')
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
    .padding({ left: 20, right: 20, top: 8, bottom: 24 });
  }

  @Builder
  boardInputBuilder(): void {
    Column({ space: 12 }) {
      TextInput({ text: this.boardUrlInput, placeholder: 'http://…/kimi-dashboard/' })
        .width('100%')
        .height(52)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_placeholder'))
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .onChange((v: string) => {
          this.boardUrlInput = v;
        });
      Button('保存并重载')
        .width('100%')
        .height(46)
        .fontSize(16)
        .fontColor('#FFFFFF')
        .backgroundColor($r('app.color.accent_color'))
        .borderRadius(12)
        .onClick(() => {
          this.saveBoardUrl();
        });
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 });
  }

  @Builder
  errorBuilder(): void {
    Column({ space: 16 }) {
      Text('看板加载失败')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'));
      Text('无法连接到看板服务，请检查网络或看板地址')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center);
      Text(this.boardUrl)
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

      Button('修改看板地址')
        .width('86%')
        .height(48)
        .fontSize(16)
        .fontColor($r('app.color.button_secondary_text'))
        .backgroundColor($r('app.color.button_secondary_bg'))
        .borderRadius(12)
        .onClick(() => {
          this.boardUrlInput = this.boardUrl;
          this.showBoardInput = true;
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
      // 背景层：填满整屏，与网页背景同色
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.web_status_bg'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);

      Column() {
        Stack() {
          // Web 须等看板地址就绪再创建：src 只在创建时生效，空地址创建后不会自动重载
          if (this.boardUrl.length > 0) {
            Refresh({ refreshing: $$this.isRefreshing }) {
            Web({ src: this.boardUrl, controller: this.controller })
              .width('100%')
              .height('100%')
              .mixedMode(MixedMode.All)
              .darkMode(WebDarkMode.Auto)
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .databaseAccess(false)
              .fileAccess(false)
              .geolocationAccess(false)
              .imageAccess(true)
              .multiWindowAccess(false)
              .keyboardAvoidMode(WebKeyboardAvoidMode.RESIZE_CONTENT)
              .onControllerAttached(() => {
                this.registerBridge();
              })
              .onRenderExited((event: OnRenderExitedEvent) => {
                console.error(`[Kimi] 渲染进程退出 reason=${event.renderExitReason}`);
                promptAction.showToast({ message: '页面异常，正在重新加载…', duration: 2000 });
                this.retry();
              })
              .onPageBegin(() => {
                console.info('[Kimi] 看板开始加载');
                this.loadFailed = false;
                this.resetStatusBar();
                if (!this.firstLoadDone) {
                  this.loading = true;
                }
                this.startLoadWatchdog();
              })
              .onPageEnd(() => {
                this.clearLoadWatchdog();
                this.loading = false;
                this.isRefreshing = false;
                this.firstLoadDone = true;
                if (!this.loadFailed) {
                  this.applySystemStatusBar();
                }
              })
              .onErrorReceive((event: OnErrorReceiveEvent) => {
                if (event && event.request.isMainFrame()) {
                  console.error(`[Kimi] 看板加载错误: ${event.error.getErrorCode()} ${event.error.getErrorInfo()}`);
                  this.clearLoadWatchdog();
                  this.loadFailed = true;
                  this.loading = false;
                  this.isRefreshing = false;
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
              console.info(`[Kimi][pinch] scale=${event.scale}`);
              this.showMenu = true;
            }));
          }

          // 首次加载态：品牌图标跳动动画
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
        }
        .width('100%')
        .layoutWeight(1);
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.statusBarHeight })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .bindSheet($$this.showBoardInput, this.boardInputBuilder(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        backgroundColor: $r('app.color.sheet_bg'),
        title: { title: '修改看板地址' },
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.web_status_bg'))
    .bindSheet($$this.showMenu, this.menuBuilder(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: $r('app.color.sheet_bg'),
      title: { title: '操作' },
    });
  }
}
