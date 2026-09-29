import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { getStatusBarHeight } from '../common/WindowUtil';
import { PreferencesUtil } from '../common/PreferencesUtil';

/**
 * 输入访问地址页：首次启动或主动修改地址时进入。
 * 自动补全协议头（缺失时按是否含局域网/IP特征决定 http/https），
 * 校验通过后保存并跳转全屏 Web 页。
 * 已保存地址会预填到输入框；历史地址列表支持点按直接切换。
 */
@Entry
@Component
struct SetupPage {
  @State private url: string = '';
  @State private history: string[] = [];
  @State private saving: boolean = false;
  /** 状态栏高度（vp），内容层顶部显式避让 */
  @State private statusBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    const ctx = getContext(this) as common.Context;
    // 预填当前地址，便于查看与微调
    this.url = await PreferencesUtil.getServerUrl(ctx);
    this.history = await PreferencesUtil.getHistory(ctx);
    // 读取状态栏高度，用于内容层顶部避让
    this.statusBarHeight = await getStatusBarHeight(ctx);
  }

  /**
   * 规范化地址：补全协议头。
   * - 已带 http:// 或 https:// 直接返回。
   * - 否则按内容猜测：纯 IP 或 localhost 或常见内网域名用 http，其余用 https。
   */
  private normalize(input: string): string {
    const trimmed = input.trim();
    if (trimmed.length === 0) {
      return '';
    }
    if (trimmed.toLowerCase().startsWith('http://') || trimmed.toLowerCase().startsWith('https://')) {
      return trimmed;
    }
    // 猜测是否为局域网/IP/localhost（含 . 且非域名，或以 192.168/10./172. 开头）
    const looksLikeLan = /^(localhost|(\d{1,3}\.){3}\d{1,3}|192\.168\.|10\.|172\.|127\.)/i.test(trimmed);
    return (looksLikeLan ? 'http://' : 'https://') + trimmed;
  }

  private isValid(url: string): boolean {
    return /^https?:\/\/.+/i.test(url) && url.length > 8;
  }

  private async onSave(): Promise<void> {
    const normalized = this.normalize(this.url);
    if (!this.isValid(normalized)) {
      promptAction.showToast({
        message: '地址格式不正确，需以 http:// 或 https:// 开头',
        duration: 2500,
      });
      return;
    }
    this.saving = true;
    try {
      const ctx = getContext(this) as common.Context;
      await PreferencesUtil.saveServerUrl(ctx, normalized);
      router.replaceUrl({ url: 'pages/WebPage' });
    } catch (e) {
      promptAction.showToast({ message: `保存失败：${(e as Error).message}`, duration: 2500 });
    } finally {
      this.saving = false;
    }
  }

  /** 点按历史地址：直接保存并进入 */
  private async onSelectHistory(url: string): Promise<void> {
    const ctx = getContext(this) as common.Context;
    await PreferencesUtil.saveServerUrl(ctx, url);
    router.replaceUrl({ url: 'pages/WebPage' });
  }

  build(): void {
    Stack() {
      // 背景层：填满整屏（含状态栏与底部区域），与内容同色，视觉一体
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_bg'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);

      // 内容层：显式扩展全屏并用 padding 避开状态栏，底部延伸到屏幕底边
      Column() {
        // 顶部标题区
        Column({ space: 8 }) {
          Text('Kimi')
            .fontSize(34)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Bold);
          Text('配置访问地址')
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .margin({ top: 96, bottom: 48 })
        .alignItems(HorizontalAlign.Center);

        // 输入卡片
        Column({ space: 16 }) {
          TextInput({ text: this.url, placeholder: 'https:// 或 http:// 开头' })
            .width('100%')
            .height(56)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_placeholder'))
            .backgroundColor($r('app.color.input_bg'))
            .borderRadius(12)
            .padding({ left: 16, right: 16 })
            .onChange((v: string) => {
              this.url = v;
            });

          Button(this.saving ? '保存中…' : '保存并进入')
            .width('100%')
            .height(52)
            .fontSize(17)
            .fontColor('#FFFFFF')
            .backgroundColor(this.saving ? $r('app.color.accent_pressed') : $r('app.color.accent_color'))
            .borderRadius(12)
            .enabled(!this.saving)
            .onClick(() => {
              this.onSave();
            });
        }
        .width('86%')
        .padding(20)
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(20);

        // 历史地址列表：点按直接切换
        if (this.history.length > 0) {
          Column({ space: 8 }) {
            Text('历史地址')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ bottom: 4 });
            ForEach(this.history, (item: string) => {
              Row() {
                Text(item)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1);
                Text('›')
                  .fontSize(18)
                  .fontColor($r('app.color.text_placeholder'));
              }
              .width('100%')
              .height(48)
              .padding({ left: 16, right: 16 })
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(12)
              .onClick(() => {
                this.onSelectHistory(item);
              });
            }, (item: string) => item);
          }
          .width('86%')
          .margin({ top: 24 });
        }

        // 提示
        Text('地址将保存在本机，下次启动直接打开。')
          .fontSize(13)
          .fontColor($r('app.color.text_placeholder'))
          .margin({ top: 24 })
          .textAlign(TextAlign.Center);
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Center)
      .padding({ top: this.statusBarHeight })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
    .width('100%')
    .height('100%');
  }
}
