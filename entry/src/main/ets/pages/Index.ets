import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PreferencesUtil } from '../common/PreferencesUtil';

/**
 * 入口分发页：根据是否已保存访问地址，跳转到输入页、看板页（默认）。
 * 该页本身只渲染一个简短加载态，不做实际展示。
 */
@Entry
@Component
struct Index {
  async aboutToAppear(): Promise<void> {
    const ctx = getContext(this) as common.Context;
    const url = await PreferencesUtil.getServerUrl(ctx);
    if (url && url.length > 0) {
      router.replaceUrl({ url: 'pages/DashboardPage' });
    } else {
      router.replaceUrl({ url: 'pages/SetupPage' });
    }
  }

  build(): void {
    Column() {
      LoadingProgress()
        .width(48)
        .height(48)
        .color($r('app.color.accent_color'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
