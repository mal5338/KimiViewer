import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[Kimi] EntryAbility onCreate');
  }

  onDestroy(): void {
    console.info('[Kimi] EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 1. 获取主窗口
    const win: window.Window = windowStage.getMainWindowSync();
    this.mainWindow = win;

    // 2. 窗口背景色跟随深浅色：避免首帧渲染前/页面切换时闪白（须在 loadContent 生效后调用）
    //    由下方 loadContent 成功回调中执行 applyWindowBackground()

    // 3. 沉浸式布局：应用自绘状态栏区域背景（与网页内容同色），内容可延伸至屏幕底边
    win.setWindowLayoutFullScreen(true)
      .then(() => {
        // 4. 只显示顶部状态栏（时间、网络等），隐藏底部手势导航条
        return win.setWindowSystemBarEnable(['status']);
      })
      .then(() => {
        // 5. 状态栏文字颜色跟随当前深浅色模式
        this.applyStatusBarStyle(this.context.config.colorMode);
        console.info('[Kimi] 状态栏设置成功');
      })
      .catch((err: BusinessError) => {
        console.error(`[Kimi] 状态栏设置失败 code=${err.code} msg=${err.message}`);
      });

    // 6. 加载首页（首页根据是否已存地址再分发到输入页或 Web 页）
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error(`[Kimi] loadContent 失败 code=${err.code} msg=${err.message}`);
        return;
      }
      console.info('[Kimi] loadContent 成功');
      // loadContent 生效后设置窗口背景色（接口要求）
      this.applyWindowBackground();
    });
  }

  /**
   * 系统配置（深浅色模式等）变化时，同步状态栏文字颜色与窗口背景色。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    this.applyStatusBarStyle(newConfig.colorMode);
    this.applyWindowBackground();
  }

  /** 窗口背景色跟随系统深浅色：深色 #121212 / 浅色 #FFFFFF（与网页/状态栏同色系） */
  private applyWindowBackground(): void {
    if (!this.mainWindow) {
      return;
    }
    const isDark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    try {
      this.mainWindow.setWindowBackgroundColor(isDark ? '#121212' : '#FFFFFF');
    } catch (err) {
      console.error(`[Kimi] 窗口背景色设置失败: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 状态栏文字颜色：深色模式用白字（配 #121212 背景），浅色模式用黑字（配白底）。
   */
  private applyStatusBarStyle(colorMode?: ConfigurationConstant.ColorMode): void {
    if (!this.mainWindow) {
      return;
    }
    const isDark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.mainWindow.setWindowSystemBarProperties({
      statusBarContentColor: isDark ? '#FFFFFF' : '#000000',
    }).catch((err: BusinessError) => {
      console.error(`[Kimi] 状态栏文字颜色设置失败 code=${err.code} msg=${err.message}`);
    });
  }

  onWindowStageDestroy(): void {
    console.info('[Kimi] EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    console.info('[Kimi] EntryAbility onForeground');
  }

  onBackground(): void {
    console.info('[Kimi] EntryAbility onBackground');
  }
}
