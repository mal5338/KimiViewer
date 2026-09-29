import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME = 'kimi_prefs';
const KEY_URL = 'server_url';
// 历史地址用换行符拼接存储（URL 不含换行），避免 JSON 反序列化的类型问题
const KEY_HISTORY = 'server_url_history';
const KEY_HINT_COUNT = 'hint_shown_count';
const KEY_PUSH_TOKEN = 'push_token';
const KEY_DASHBOARD_URL = 'dashboard_url';
/** 看板默认地址（首次启动由用户在设置页填写 kimi-dashboard 服务地址） */
const DEFAULT_DASHBOARD_URL = '';
const HISTORY_MAX = 5;
const HINT_MAX = 2;

/**
 * 封装 Kimi 访问地址的本地持久化读写。
 * 使用 @ohos.data.preferences，存储在应用私有目录，重启后仍可读取。
 */
export class PreferencesUtil {
  private static getStore(context: common.Context): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, STORE_NAME);
  }

  /**
   * 保存访问地址，并更新历史记录（去重置顶，最多保留 HISTORY_MAX 条）。
   */
  static async saveServerUrl(context: common.Context, url: string): Promise<void> {
    const store = await PreferencesUtil.getStore(context);
    await store.put(KEY_URL, url);
    const history = await PreferencesUtil.getHistory(context);
    const next = [url].concat(history.filter((u) => u !== url)).slice(0, HISTORY_MAX);
    await store.put(KEY_HISTORY, next.join('\n'));
    await store.flush();
    console.info(`[Kimi] 地址已保存: ${url}`);
  }

  /**
   * 读取已保存的访问地址，未保存时返回空字符串。
   */
  static async getServerUrl(context: common.Context): Promise<string> {
    const store = await PreferencesUtil.getStore(context);
    const val = await store.get(KEY_URL, '');
    return val as string;
  }

  /**
   * 读取历史地址列表（最新的在前）。
   */
  static async getHistory(context: common.Context): Promise<string[]> {
    const store = await PreferencesUtil.getStore(context);
    const raw = (await store.get(KEY_HISTORY, '')) as string;
    return raw.split('\n').filter((u) => u.length > 0);
  }

  /**
   * 是否应该显示操作手势提示：前 HINT_MAX 次进入时返回 true，之后不再提示。
   */
  static async shouldShowHint(context: common.Context): Promise<boolean> {
    const store = await PreferencesUtil.getStore(context);
    const count = (await store.get(KEY_HINT_COUNT, 0)) as number;
    if (count >= HINT_MAX) {
      return false;
    }
    await store.put(KEY_HINT_COUNT, count + 1);
    await store.flush();
    return true;
  }

  /**
   * 保存/读取华为推送 Token（供用户复制到 Mac 端推送配置）。
   */
  static async savePushToken(context: common.Context, token: string): Promise<void> {
    const store = await PreferencesUtil.getStore(context);
    await store.put(KEY_PUSH_TOKEN, token);
    await store.flush();
  }

  static async getPushToken(context: common.Context): Promise<string> {
    const store = await PreferencesUtil.getStore(context);
    return (await store.get(KEY_PUSH_TOKEN, '')) as string;
  }

  /**
   * 保存看板地址（去空格；空值视为恢复默认）。
   */
  static async saveDashboardUrl(context: common.Context, url: string): Promise<void> {
    const store = await PreferencesUtil.getStore(context);
    const trimmed = url.trim();
    await store.put(KEY_DASHBOARD_URL, trimmed.length > 0 ? trimmed : DEFAULT_DASHBOARD_URL);
    await store.flush();
  }

  /**
   * 读取看板地址，未保存过时返回默认地址。
   */
  static async getDashboardUrl(context: common.Context): Promise<string> {
    const store = await PreferencesUtil.getStore(context);
    const val = await store.get(KEY_DASHBOARD_URL, DEFAULT_DASHBOARD_URL);
    const url = val as string;
    return url.length > 0 ? url : DEFAULT_DASHBOARD_URL;
  }
}
