import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

/**
 * 获取系统状态栏高度（vp），失败返回 0。
 * 供页面做内容层顶部避让使用。
 */
export async function getStatusBarHeight(context: common.Context): Promise<number> {
  try {
    const win = await window.getLastWindow(context);
    const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    return px2vp(area.topRect.height);
  } catch (e) {
    console.warn(`[Kimi] 获取状态栏高度失败: ${JSON.stringify(e)}`);
    return 0;
  }
}
