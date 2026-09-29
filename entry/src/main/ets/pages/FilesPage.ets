import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { getStatusBarHeight } from '../common/WindowUtil';
import { PreferencesUtil } from '../common/PreferencesUtil';

/** 文件/目录项（会话级 /fs:list 返回结构） */
interface FsEntry {
  name: string;
  path: string;
  isDir: boolean;
  size: number;
  modifiedAt: string;
}

/** 排序方式 */
enum SortBy {
  NAME = 0,
  TIME = 1,
  SIZE = 2,
  TYPE = 3,
}

/** 视图模式 */
enum ViewMode {
  LIST = 0,
  GRID = 1,
}

/** 面包屑层级段 */
interface CrumbSeg {
  name: string;
  path: string;
}

/** 代码高亮文本段 */
interface TextSeg {
  text: string;
  color: ResourceColor;
}

/** 语法高亮长度上限：超长部分保持默认色（控制 span 数量与内存），对齐安卓版 */
const HIGHLIGHT_MAX_CHARS = 32768;

const SORT_LABELS: string[] = ['按名称排序', '按时间排序', '按大小排序', '按类型排序'];

/**
 * 远程文件浏览页：浏览当前会话工作空间内的文件（对齐安卓版 FilesActivity 的
 * 浏览方式与样式：类型徽标、可点击面包屑、HTML 渲染/源码切换、代码高亮）。
 * 数据来自会话级 /api/v1/sessions/{sid}/fs:list（相对路径，天然限制在工作空间内，
 * 且携带 size/modified_at）。入口：会话页操作菜单「浏览文件」。
 * 会话 ID 由 WebPage 通过 router 参数传入。
 */
@Entry
@Component
struct FilesPage {
  /** 服务基地址（http://host:port），由保存的访问地址解析 */
  @State private baseUrl: string = '';
  /** Bearer token（从地址 fragment 解析） */
  private token: string = '';
  /** 当前会话 ID（router 参数） */
  private sessionId: string = '';
  /** 工作空间根目录的绝对路径（fetchFile 转换用） */
  @State private workspaceRoot: string = '';
  /** 当前目录相对路径（工作空间内；'' 表示根） */
  @State private currentPath: string = '';
  /** 目录条目列表 */
  @State private entries: FsEntry[] = [];
  /** 显示中的条目（应用排序后） */
  @State private sortedEntries: FsEntry[] = [];
  /** 加载中 */
  @State private loading: boolean = false;
  /** 错误信息（非空时显示错误态） */
  @State private error: string = '';
  /** 下载中的文件路径集合 */
  @State private downloading: Set<string> = new Set();
  /** 状态栏高度（vp） */
  @State private statusBarHeight: number = 0;
  /** 排序方式 */
  @State private sortBy: SortBy = SortBy.TIME;
  /** 视图模式：列表 / 网格 */
  @State private viewMode: ViewMode = ViewMode.LIST;
  /** 排序菜单开关 */
  @State private showSortMenu: boolean = false;
  /** 多选模式开关（对齐鸿蒙文件管理"多选"） */
  @State private multiSelect: boolean = false;
  /** 多选已选路径集合 */
  @State private selectedPaths: Set<string> = new Set();
  /** 批量下载/分享处理中 */
  @State private batchDownloading: boolean = false;
  /** 搜索模式开关 */
  @State private searchMode: boolean = false;
  /** 搜索关键字（客户端过滤当前目录） */
  @State private searchKey: string = '';
  /** 预览中的文件（非空时显示预览覆盖层） */
  @State private previewEntry: FsEntry | null = null;
  /** 预览内容加载中 */
  @State private previewLoading: boolean = false;
  /** 预览图片的 PixelMap */
  @State private previewPixelMap: image.PixelMap | null = null;
  /** 预览文本内容 */
  @State private previewText: string = '';
  /** 预览 HTML 内容（MD/HTML 渲染用） */
  @State private previewHtml: string = '';
  /** 预览 Web 的 data URI（base64，绕开 loadData 白屏问题） */
  @State private previewDataUri: string = '';
  /** 当前预览文件所在目录（相对路径，链接跳转解析用） */
  private currentBaseDir: string = '';
  /** 预览沙箱文件路径（视频等需要先落盘的类型） */
  @State private previewLocalPath: string = '';
  /** 预览错误信息 */
  @State private previewError: string = '';
  /** HTML 预览视图切换：false=渲染（Web），true=源码 */
  @State private previewShowSource: boolean = false;
  /** 代码高亮文本段（非空时源码视图按段着色渲染） */
  @State private previewSegs: TextSeg[] = [];
  /** 预览历史栈（链接跳转记录，返回时逐级恢复） */
  private previewHistory: FsEntry[] = [];
  /** MD/HTML 预览的 Web 控制器 */
  private previewWebController: webview.WebviewController = new webview.WebviewController();
  /** 面包屑横向滚动控制器（自动滚到最右显示当前层） */
  private crumbScroller: Scroller = new Scroller();
  /** 分享面板控制器（成员变量保活：局部变量会被 GC 导致面板闪退） */
  private shareController: systemShare.ShareController | null = null;

  async aboutToAppear(): Promise<void> {
    const ctx = getContext(this) as common.Context;
    this.statusBarHeight = await getStatusBarHeight(ctx);
    // 会话 ID：router 参数优先（WebPage 传入），缺省取最近会话
    const params = router.getParams() as Record<string, string>;
    this.sessionId = params?.sessionId ?? '';
    const url = await PreferencesUtil.getServerUrl(ctx);
    console.info(`[Kimi][files] 保存的地址长度=${url.length} 含#=${url.indexOf('#') >= 0} 含token=${url.indexOf('token=') >= 0}`);
    const hashIndex = url.indexOf('#');
    const base = hashIndex >= 0 ? url.substring(0, hashIndex) : url;
    this.baseUrl = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    const m = url.match(/#token=([^&]+)/);
    this.token = m ? m[1] : '';
    if (!this.baseUrl || !this.token) {
      this.error = '未获取到有效的访问地址或令牌，请回到会话页重新进入';
      return;
    }
    if (!this.sessionId) {
      this.sessionId = await this.getLatestSessionId();
    }
    if (!this.sessionId) {
      this.error = '未找到会话，请先在会话页打开一个会话';
      return;
    }
    // 解析会话所在工作空间的绝对根目录（fetchFile 顶层 fs:content 需要绝对路径）
    this.workspaceRoot = await this.getWorkspaceRoot();
    if (!this.workspaceRoot) {
      this.error = '未找到工作空间根目录';
      return;
    }
    await this.loadDir('');
  }

  /** 会话 → workspace_id → 工作空间绝对根目录 */
  private async getWorkspaceRoot(): Promise<string> {
    try {
      const resp = await this.apiRequest(`/api/v1/sessions/${this.sessionId}`) as Record<string, Object>;
      const data = (resp?.data as Record<string, string>) ?? {};
      const wsId = data?.workspace_id ?? '';
      if (wsId.length === 0) {
        return '';
      }
      const wsResp = await this.apiRequest('/api/v1/workspaces') as Record<string, Object>;
      const wsData = (wsResp?.data as Record<string, Object[]>) ?? {};
      const items = wsData?.items ?? [];
      for (const it of items) {
        const w = it as Record<string, string>;
        if (w?.id === wsId) {
          return w?.root ?? '';
        }
      }
    } catch (e) {
      // 忽略，返回空
    }
    return '';
  }

  /** 取最近更新的会话 ID（未传参时的兜底） */
  private async getLatestSessionId(): Promise<string> {
    try {
      const resp = await this.apiRequest('/api/v1/sessions?limit=1') as Record<string, Object>;
      const data = (resp?.data as Record<string, Object[]>) ?? {};
      const items = data?.items ?? [];
      if (items.length > 0) {
        const s = items[0] as Record<string, string>;
        return s?.id ?? '';
      }
    } catch (e) {
      // 忽略
    }
    return '';
  }

  /** 带鉴权的 GET 请求，返回解析后的 JSON */
  private async apiRequest(apiPath: string): Promise<object | string> {
    return new Promise<object | string>((resolve, reject) => {
      const req = http.createHttp();
      req.request(`${this.baseUrl}${apiPath}`, {
        method: http.RequestMethod.GET,
        header: { 'Authorization': `Bearer ${this.token}` },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000,
      }).then((resp) => {
        req.destroy();
        if (resp.responseCode !== 200) {
          reject(new Error(`HTTP ${resp.responseCode}`));
          return;
        }
        const body = resp.result as string;
        try {
          resolve(JSON.parse(body));
        } catch (e) {
          resolve(body);
        }
      }).catch((e: Error) => {
        req.destroy();
        reject(e);
      });
    });
  }

  /** 带鉴权下载文件到 ArrayBuffer（path 为工作空间相对路径；转绝对路径走顶层 GET /fs:content） */
  private async fetchFile(relPath: string): Promise<ArrayBuffer> {
    const absPath = this.workspaceRoot.length > 0
      ? `${this.workspaceRoot}/${relPath}` : relPath;
    return new Promise<ArrayBuffer>((resolve, reject) => {
      const req = http.createHttp();
      req.request(`${this.baseUrl}/api/v1/fs:content?path=${encodeURIComponent(absPath)}`,
        {
          method: http.RequestMethod.GET,
          header: {
            'Authorization': `Bearer ${this.token}`,
          },
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 15000,
          readTimeout: 60000,
        }).then((resp) => {
          req.destroy();
          if (resp.responseCode !== 200) {
            reject(new Error(`HTTP ${resp.responseCode}`));
            return;
          }
          resolve(resp.result as ArrayBuffer);
        }).catch((e: Error) => {
          req.destroy();
          reject(e);
        });
    });
  }

  /** 加载目录列表（relPath 为工作空间内相对路径，'' 表示根） */
  private async loadDir(relPath: string): Promise<void> {
    this.loading = true;
    this.error = '';
    try {
      const list = await this.postList(relPath);
      this.currentPath = relPath;
      this.entries = list;
      this.applySort();
    } catch (e) {
      this.error = `加载失败：${(e as Error).message}`;
      this.entries = [];
      this.sortedEntries = [];
    } finally {
      this.loading = false;
    }
  }

  /** POST /sessions/{sid}/fs:list，返回统一条目结构 */
  private async postList(relPath: string): Promise<FsEntry[]> {
    return new Promise<FsEntry[]>((resolve, reject) => {
      const req = http.createHttp();
      req.request(`${this.baseUrl}/api/v1/sessions/${this.sessionId}/fs:list`, {
        method: http.RequestMethod.POST,
        header: {
          'Authorization': `Bearer ${this.token}`,
          'Content-Type': 'application/json',
        },
        extraData: JSON.stringify({ path: relPath.length > 0 ? relPath : '.' }),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000,
      }).then((resp) => {
        req.destroy();
        if (resp.responseCode !== 200) {
          reject(new Error(`HTTP ${resp.responseCode}`));
          return;
        }
        try {
          const body = JSON.parse(resp.result as string) as Record<string, Object>;
          const data = body?.data as Record<string, Object> ?? {};
          const items = (data?.items ?? []) as Record<string, Object>[];
          const list: FsEntry[] = [];
          for (const it of items) {
            list.push({
              name: it.name as string,
              path: it.path as string,
              isDir: it.kind === 'directory',
              size: typeof it.size === 'number' ? it.size : 0,
              modifiedAt: typeof it.modified_at === 'string' ? it.modified_at : '',
            });
          }
          resolve(list);
        } catch (e) {
          reject(new Error('响应解析失败'));
        }
      }).catch((e: Error) => {
        req.destroy();
        reject(e);
      });
    });
  }

  /** 应用当前排序并刷新显示列表 */
  private applySort(): void {
    const list = [...this.entries];
    list.sort((a: FsEntry, b: FsEntry): number => {
      if (a.isDir !== b.isDir) {
        return a.isDir ? -1 : 1; // 目录永远在前
      }
      switch (this.sortBy) {
        case SortBy.NAME:
          return a.name.localeCompare(b.name);
        case SortBy.TIME:
          return b.modifiedAt.localeCompare(a.modifiedAt);
        case SortBy.SIZE:
          return b.size - a.size;
        case SortBy.TYPE:
          return this.extOf(a.name).localeCompare(this.extOf(b.name)) || a.name.localeCompare(b.name);
        default:
          return 0;
      }
    });
    this.sortedEntries = list;
  }

  /** 文件扩展名 */
  private extOf(name: string): string {
    const dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  /** 下载文件到应用沙箱，并调起系统分享面板（可另存到文件管理/发送到其他应用） */
  private async downloadFile(entry: FsEntry): Promise<void> {
    this.downloading.add(entry.path);
    try {
      const buf = await this.fetchFile(entry.path);
      const ctx = getContext(this) as common.Context;
      const target = `${ctx.filesDir}/${entry.name}`;
      const file = fileIo.openSync(target, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, buf);
      fileIo.closeSync(file);
      // 弹出系统分享面板：用户可保存到文件管理/图库，或发到微信等应用
      this.shareFile(target, entry.name);
    } catch (e) {
      promptAction.showToast({ message: `下载失败：${(e as Error).message}`, duration: 3000 });
    } finally {
      this.downloading.delete(entry.path);
    }
  }

  /** 扩展名 → 系统 UTD 类型（硬编码映射，确保微信/钉钉能匹配到目标） */
  private utdOf(name: string): string {
    const ext = this.extOf(name);
    const imageExts: string[] = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg'];
    const videoExts: string[] = ['mp4', 'mov', 'mkv', 'webm', 'avi'];
    const audioExts: string[] = ['mp3', 'wav', 'flac', 'aac', 'm4a'];
    const archiveExts: string[] = ['zip', 'gz', 'tar', 'rar', '7z'];
    const textExts: string[] = ['txt', 'log', 'md', 'csv', 'ini', 'cfg'];
    if (imageExts.includes(ext)) {
      return 'general.image';
    }
    if (videoExts.includes(ext)) {
      return 'general.video';
    }
    if (audioExts.includes(ext)) {
      return 'general.audio';
    }
    if (archiveExts.includes(ext)) {
      return 'general.archive';
    }
    if (ext === 'pdf') {
      return 'general.pdf';
    }
    if (ext === 'html' || ext === 'htm') {
      return 'general.html';
    }
    if (textExts.includes(ext)) {
      return 'general.plain-text';
    }
    return 'general.file';
  }

  /** 通过 Share Kit 系统分享面板分享沙箱文件（可选保存到文件管理/图库、发微信等） */
  private shareFile(filePath: string, displayName: string): void {
    let uri = '';
    try {
      uri = fileUri.getUriFromPath(filePath);
    } catch (e) {
      promptAction.showToast({ message: `分享失败（URI 生成）：${(e as Error).message}`, duration: 3000 });
      return;
    }
    // UTD 类型：硬编码映射（getUniformDataTypeByFilenameExtension 在部分扩展名上抛参数错误）
    let utd = this.utdOf(displayName);
    let data: systemShare.SharedData;
    try {
      const record: systemShare.SharedRecord = {
        utd: utd,
        uri: uri,
        title: displayName,
      };
      data = new systemShare.SharedData(record);
      console.info(`[Kimi][share] SharedData 构造成功 utd=${utd} uri=${uri.substring(0, 60)}`);
    } catch (e) {
      promptAction.showToast({ message: `分享失败（数据构造）：${(e as Error).message}`, duration: 3000 });
      return;
    }
    try {
      const controller = new systemShare.ShareController(data);
      this.shareController = controller; // 成员变量保活，防止面板被 GC 提前关闭
      const ctx = getContext(this) as common.UIAbilityContext;
      // 预览模式：图片/视频用 DETAIL（大图预览），其余用 DEFAULT（卡片），避免非媒体类型 reject
      const isMedia = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'mp4', 'mov', 'mkv', 'webm']
        .includes(this.extOf(displayName));
      controller.show(ctx, {
        previewMode: isMedia ? systemShare.SharePreviewMode.DETAIL : systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE,
      }).catch((e: Error) => {
        promptAction.showToast({ message: `分享面板拉起失败：${e.message}`, duration: 3000 });
      });
    } catch (e) {
      promptAction.showToast({ message: `分享失败：${(e as Error).message}`, duration: 3000 });
    }
  }

  /** 展示条目：搜索关键字非空时按名称子串过滤当前目录（客户端过滤，不重新请求） */
  private displayEntries(): FsEntry[] {
    const key = this.searchKey.trim().toLowerCase();
    if (key.length === 0) {
      return this.sortedEntries;
    }
    return this.sortedEntries.filter((e: FsEntry) => e.name.toLowerCase().includes(key));
  }

  /** 多选：切换某条目选中态 */
  private toggleSelect(path: string): void {
    const next = new Set(this.selectedPaths);
    if (next.has(path)) {
      next.delete(path);
    } else {
      next.add(path);
    }
    this.selectedPaths = next;
  }

  /** 退出多选并清空选择 */
  private exitMultiSelect(): void {
    this.multiSelect = false;
    this.selectedPaths = new Set();
  }

  /** 已选中的文件条目（目录不支持下载/分享） */
  private selectedFileEntries(): FsEntry[] {
    return this.sortedEntries.filter((e: FsEntry) => !e.isDir && this.selectedPaths.has(e.path));
  }

  /** 拉取文件内容并写入应用沙箱，返回本地路径 */
  private async fetchAndSave(entry: FsEntry): Promise<string> {
    const buf = await this.fetchFile(entry.path);
    const ctx = getContext(this) as common.Context;
    const target = `${ctx.filesDir}/${entry.name}`;
    const file = fileIo.openSync(target, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, buf);
    fileIo.closeSync(file);
    return target;
  }

  /** 批量下载：选中文件逐个保存到应用沙箱 */
  private async batchDownload(): Promise<void> {
    const targets = this.selectedFileEntries();
    if (targets.length === 0) {
      promptAction.showToast({ message: '请选择文件（目录不支持下载）', duration: 2500 });
      return;
    }
    this.batchDownloading = true;
    try {
      for (const t of targets) {
        await this.fetchAndSave(t);
      }
      promptAction.showToast({ message: `已下载 ${targets.length} 个文件`, duration: 2500 });
      this.exitMultiSelect();
    } catch (e) {
      promptAction.showToast({ message: `批量下载失败：${(e as Error).message}`, duration: 3000 });
    } finally {
      this.batchDownloading = false;
    }
  }

  /** 批量分享：全部下载后合并进一个系统分享面板 */
  private async batchShare(): Promise<void> {
    const targets = this.selectedFileEntries();
    if (targets.length === 0) {
      promptAction.showToast({ message: '请选择文件（目录不支持分享）', duration: 2500 });
      return;
    }
    this.batchDownloading = true;
    try {
      const records: systemShare.SharedRecord[] = [];
      for (const t of targets) {
        const local = await this.fetchAndSave(t);
        records.push({
          utd: this.utdOf(t.name),
          uri: fileUri.getUriFromPath(local),
          title: t.name,
        });
      }
      const data = new systemShare.SharedData(records[0]);
      for (let i = 1; i < records.length; i++) {
        data.addRecord(records[i]);
      }
      const controller = new systemShare.ShareController(data);
      this.shareController = controller;
      const ctx = getContext(this) as common.UIAbilityContext;
      controller.show(ctx, {
        selectionMode: systemShare.SelectionMode.SINGLE,
      }).catch((e: Error) => {
        promptAction.showToast({ message: `分享面板拉起失败：${e.message}`, duration: 3000 });
      });
      this.exitMultiSelect();
    } catch (e) {
      promptAction.showToast({ message: `批量分享失败：${(e as Error).message}`, duration: 3000 });
    } finally {
      this.batchDownloading = false;
    }
  }

  /** 大小格式化 */
  private formatSize(bytes: number): string {
    if (bytes <= 0) {
      return '';
    }
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    }
    return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
  }

  // ---- 预览功能：按类型分发 ----

  /** 图片扩展名集合 */
  private static readonly IMAGE_EXTS: string[] = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg'];
  /** 文本/代码扩展名集合 */
  private static readonly TEXT_EXTS: string[] =
    ['txt', 'md', 'log', 'json', 'xml', 'yaml', 'yml', 'toml', 'ts', 'ets', 'js', 'py', 'java', 'kt',
      'c', 'cpp', 'h', 'swift', 'go', 'rs', 'css', 'scss', 'html', 'htm', 'sh', 'gitignore', 'cfg', 'ini'];
  /** 视频扩展名集合 */
  private static readonly VIDEO_EXTS: string[] = ['mp4', 'mov', 'mkv', 'webm'];

  private isImage(name: string): boolean {
    return FilesPage.IMAGE_EXTS.includes(this.extOf(name));
  }

  private isText(name: string): boolean {
    return FilesPage.TEXT_EXTS.includes(this.extOf(name)) || this.extOf(name).length === 0 && name.startsWith('.');
  }

  private isVideo(name: string): boolean {
    return FilesPage.VIDEO_EXTS.includes(this.extOf(name));
  }

  private isPdf(name: string): boolean {
    return this.extOf(name) === 'pdf';
  }

  private isHtml(name: string): boolean {
    return ['html', 'htm'].includes(this.extOf(name));
  }

  private isMarkdown(name: string): boolean {
    return this.extOf(name) === 'md';
  }

  /** 是否可预览（入口判断：不可预览时点行仍走下载） */
  private isPreviewable(entry: FsEntry): boolean {
    return this.isImage(entry.name) || this.isText(entry.name) || this.isVideo(entry.name) || this.isPdf(entry.name);
  }

  /** 打开预览：按类型加载内容 */
  private async openPreview(entry: FsEntry): Promise<void> {
    this.previewEntry = entry;
    this.previewLoading = true;
    this.previewError = '';
    this.previewPixelMap = null;
    this.previewText = '';
    this.previewLocalPath = '';
    this.previewHtml = '';
    this.previewDataUri = '';
    this.previewShowSource = false;
    this.previewSegs = [];
    // 记录当前文件所在目录（相对路径），供预览内链接跳转解析
    const slash = entry.path.lastIndexOf('/');
    this.currentBaseDir = slash >= 0 ? entry.path.substring(0, slash) : '';
    try {
      if (entry.size > 5 * 1024 * 1024) {
        this.previewError = '文件较大，建议下载后查看';
        return;
      }
      const buf = await this.fetchFile(entry.path);
      if (this.isImage(entry.name)) {
        const source = image.createImageSource(buf);
        this.previewPixelMap = await source.createPixelMap();
        source.release();
      } else if (this.isVideo(entry.name) || this.isPdf(entry.name)) {
        // 视频/PDF 需先落盘再用组件加载
        const ctx = getContext(this) as common.Context;
        const target = `${ctx.filesDir}/${entry.name}`;
        const file = fileIo.openSync(target, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, buf);
        fileIo.closeSync(file);
        this.previewLocalPath = target;
      } else if (this.isHtml(entry.name) || this.isMarkdown(entry.name)) {
        // HTML/MD：转成带样式的 HTML 文档，base64 data URI 交给 Web 渲染
        // （loadData 在部分场景下白屏，data URI 走标准加载通道更可靠）
        const decoder = util.TextDecoder.create('utf-8');
        const content = decoder.decodeToString(new Uint8Array(buf));
        const body = this.isMarkdown(entry.name) ? this.markdownToHtml(content) : content;
        const html = this.wrapHtmlDocument(body, entry.name, entry.path);
        const encoder = new util.TextEncoder();
        const bytes = encoder.encodeInto(html);
        const base64 = new util.Base64Helper();
        this.previewDataUri = 'data:text/html;base64,' + base64.encodeToStringSync(bytes);
        if (this.isHtml(entry.name)) {
          // HTML 保留原始内容供"源码"视图（含高亮段）
          this.previewText = content;
          this.previewSegs = this.highlightSegments(content);
        }
      } else {
        // 纯文本：ArrayBuffer → UTF-8 字符串
        const decoder = util.TextDecoder.create('utf-8');
        this.previewText = decoder.decodeToString(new Uint8Array(buf));
        if (this.previewText.length > 200000) {
          this.previewText = this.previewText.substring(0, 200000) + '\n…（内容过长，已截断）';
        }
        // 代码/标记文件按段着色（对齐安卓版的轻量语法高亮）
        this.previewSegs = this.isCodeFile(entry.name) ? this.highlightSegments(this.previewText) : [];
      }
    } catch (e) {
      this.previewError = `预览失败：${(e as Error).message}`;
    } finally {
      this.previewLoading = false;
    }
  }

  /** 简易 Markdown → HTML 转换（标题/粗斜体/代码块/行内代码/列表/链接/引用/表格） */
  private markdownToHtml(md: string): string {
    // 转义 HTML 特殊字符
    const esc = (s: string): string =>
      s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    const lines = md.split('\n');
    const out: string[] = [];
    let inCode = false;
    let inList = false;
    let codeBuf: string[] = [];
    const closeList = (): void => {
      if (inList) {
        out.push('</ul>');
        inList = false;
      }
    };
    // 表格缓存：第一行表头、第二行分隔（|---|）、之后数据行
    let tableRows: string[][] = [];
    const flushTable = (): void => {
      if (tableRows.length === 0) {
        return;
      }
      // 第一行为表头
      let html = '<table><thead><tr>';
      for (const cell of tableRows[0]) {
        html += `<th>${cell}</th>`;
      }
      html += '</tr></thead><tbody>';
      for (let r = 1; r < tableRows.length; r++) {
        html += '<tr>';
        for (const cell of tableRows[r]) {
          html += `<td>${cell}</td>`;
        }
        html += '</tr>';
      }
      html += '</tbody></table>';
      out.push(html);
      tableRows = [];
    };
    // 拆分表格行单元格：| a | b | → [a, b]（去掉首尾空）
    const splitRow = (line: string): string[] => {
      const trimmed = line.trim();
      const inner = trimmed.startsWith('|') ? trimmed.substring(1) : trimmed;
      const body = inner.endsWith('|') ? inner.substring(0, inner.length - 1) : inner;
      return body.split('|').map((c) => c.trim());
    };
    // 分隔行判定：| --- | :---: | 之类（仅含 -、:、|、空格）
    const isSeparator = (line: string): boolean =>
      /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(line);
    for (const raw of lines) {
      const line = raw;
      if (line.trim().startsWith('```')) {
        flushTable();
        closeList();
        if (inCode) {
          out.push(`<pre><code>${esc(codeBuf.join('\n'))}</code></pre>`);
          codeBuf = [];
          inCode = false;
        } else {
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        codeBuf.push(line);
        continue;
      }
      // 表格行收集（含表头行与数据行；分隔行跳过）
      const looksTableRow = line.trim().startsWith('|') && line.trim().length > 1;
      if (looksTableRow) {
        if (isSeparator(line)) {
          continue; // 分隔行，表头已在缓存第一行
        }
        tableRows.push(splitRow(line).map((c) => {
          // 单元格内应用行内格式（粗体/代码/链接等）
          const innerFmt = (s: string): string =>
            esc(s)
              .replace(/`([^`]+)`/g, '<code>$1</code>')
              .replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
              .replace(/\*([^*]+)\*/g, '<i>$1</i>')
              .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>');
          return innerFmt(c);
        }));
        continue;
      }
      flushTable();
      // 行内格式：代码、粗体、斜体、链接
      const inline = (s: string): string =>
        esc(s)
          .replace(/`([^`]+)`/g, '<code>$1</code>')
          .replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
          .replace(/\*([^*]+)\*/g, '<i>$1</i>')
          .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>');
      const heading = line.match(/^(#{1,6})\s+(.*)$/);
      if (heading) {
        closeList();
        const level = Math.min(heading[1].length + 1, 6);
        out.push(`<h${level}>${inline(heading[2])}</h${level}>`);
        continue;
      }
      const bullet = line.match(/^\s*[-*]\s+(.*)$/);
      if (bullet) {
        if (!inList) {
          out.push('<ul>');
          inList = true;
        }
        out.push(`<li>${inline(bullet[1])}</li>`);
        continue;
      }
      closeList();
      if (line.trim().startsWith('>')) {
        out.push(`<blockquote>${inline(line.trim().substring(1).trim())}</blockquote>`);
        continue;
      }
      if (line.trim().length === 0) {
        continue;
      }
      out.push(`<p>${inline(line)}</p>`);
    }
    closeList();
    flushTable();
    if (inCode) {
      out.push(`<pre><code>${esc(codeBuf.join('\n'))}</code></pre>`);
    }
    return out.join('\n');
  }

  /** 包一层移动端友好的 HTML 文档（跟随深浅色） */
  private wrapHtmlDocument(body: string, title: string, relPath: string): string {
    return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>
  body {
    font-family: -apple-system, "PingFang SC", "HarmonyOS Sans", sans-serif;
    margin: 0;
    padding: 16px;
    background: #121212;
    color: #E6E6E6;
    line-height: 1.7;
    word-break: break-word;
  }
  @media (prefers-color-scheme: light) {
    body { background: #FFFFFF; color: #262626; }
    pre, code { background: #F2F2F2; color: #262626; }
    blockquote { border-color: #3D5AFE; color: #666; }
    a { color: #1A56DB; }
  }
  h1, h2, h3, h4, h5, h6 { line-height: 1.4; margin: 1em 0 .5em; }
  pre {
    background: #1E1E1E; color: #E6E6E6;
    padding: 12px; border-radius: 10px;
    overflow-x: auto; font-size: 13px;
    font-family: "JetBrains Mono", Menlo, monospace;
  }
  code { background: #1E1E1E; border-radius: 4px; padding: 1px 5px; font-size: 0.9em; }
  pre code { background: none; padding: 0; }
  blockquote {
    margin: .6em 0; padding: 4px 12px;
    border-left: 3px solid #3D5AFE; color: #999;
  }
  a { color: #7B9BFF; text-decoration: none; }
  ul { padding-left: 1.4em; }
  img { max-width: 100%; }
  table {
    border-collapse: collapse;
    width: 100%;
    margin: .8em 0;
    font-size: 13px;
    display: block;
    overflow-x: auto;
    white-space: nowrap;
  }
  th, td {
    border: 1px solid #3A3A3A;
    padding: 6px 10px;
    text-align: left;
  }
  th {
    background: #1E1E1E;
    font-weight: 600;
  }
  @media (prefers-color-scheme: light) {
    th, td { border-color: #D9D9D9; }
    th { background: #F2F2F2; }
  }
</style>
</head>
<body>
${body}
</body>
<script>
(function () {
  document.addEventListener('click', function (e) {
    var a = e.target && e.target.closest ? e.target.closest('a') : null;
    if (!a) return;
    var href = a.getAttribute('href') || '';
    if (!href) return;
    if (/^(https?:|mailto:)/i.test(href)) return; // 外部链接走默认行为
    e.preventDefault();
    if (window.kimiPreviewLink && window.kimiPreviewLink.open) {
      window.kimiPreviewLink.open(href);
    }
  }, true);
  window.__KIMI_REL__ = ${JSON.stringify(relPath)};
})();
</script>
</html>`;
  }

  /** 返回：有跳转历史则回上一个文件，否则关闭预览回文件列表 */
  private closePreview(): void {
    if (this.previewHistory.length > 0) {
      const prev = this.previewHistory.pop() as FsEntry;
      this.openPreview(prev);
      return;
    }
    this.previewEntry = null;
    this.previewPixelMap = null;
    this.previewText = '';
    this.previewHtml = '';
    this.previewDataUri = '';
    this.previewLocalPath = '';
    this.previewError = '';
    this.previewHistory = [];
    this.previewShowSource = false;
    this.previewSegs = [];
  }

  /**
   * 预览内 MD 相对链接跳转（由注入脚本通过 window.kimiPreviewLink 调用；
   * 须保持 public 供 JS 代理访问）。href 为 md 内写的路径：
   * - 以 / 开头：工作空间根的绝对路径
   * - 其他：相对当前文件所在目录
   */
  open(href: string): void {
    if (!href || href.startsWith('http')) {
      return;
    }
    // 去掉锚点（#section）
    const hashIdx = href.indexOf('#');
    const target = hashIdx >= 0 ? href.substring(0, hashIdx) : href;
    if (target.length === 0) {
      return; // 纯锚点链接，留在当前页
    }
    // Windows 反斜杠统一为正斜杠
    const normalized = target.replace(/\\/g, '/').trim();
    // 以 / 开头 = 工作空间根路径；否则相对当前文件目录拼接
    const combined = normalized.startsWith('/')
      ? normalized
      : (this.currentBaseDir.length > 0 ? `${this.currentBaseDir}/${normalized}` : normalized);
    const parts: string[] = [];
    for (const seg of combined.split('/')) {
      if (seg.length === 0 || seg === '.') {
        continue;
      }
      if (seg === '..') {
        if (parts.length > 0) {
          parts.pop();
        }
        continue;
      }
      parts.push(seg);
    }
    if (parts.length === 0) {
      return;
    }
    const resolved = parts.join('/');
    // 构造预览目标（名称取路径最后一段）
    const name = parts[parts.length - 1];
    const entry: FsEntry = {
      name: name,
      path: resolved,
      isDir: false,
      size: 0,
      modifiedAt: '',
    };
    // 压入历史栈，返回时恢复当前文件
    if (this.previewEntry !== null) {
      this.previewHistory.push(this.previewEntry);
    }
    this.openPreview(entry);
  }

  /** 源码/文本视图：有高亮段时按段着色，否则纯文本（等宽字体） */
  @Builder
  previewSourceView(): void {
    Scroll() {
      if (this.previewSegs.length > 0) {
        Text() {
          ForEach(this.previewSegs, (seg: TextSeg) => {
            Span(seg.text).fontColor(seg.color)
          }, (seg: TextSeg, idx: number) => `${idx}`)
        }
          .fontSize(12)
          .fontFamily('monospace')
          .padding(14)
          .width('100%');
      } else {
        Text(this.previewText)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .fontFamily('monospace')
          .padding(14)
          .width('100%');
      }
    }
    .scrollBar(BarState.Auto)
    .width('100%')
    .layoutWeight(1);
  }

  /** 是否按代码文件做语法高亮（对齐安卓版 isCodeFile，另含 ets/swift/kt） */
  private isCodeFile(name: string): boolean {
    return ['ts', 'tsx', 'ets', 'js', 'jsx', 'mjs', 'java', 'kt', 'kts', 'json', 'json5', 'jsonc',
      'css', 'scss', 'py', 'sh', 'html', 'htm', 'xml', 'gradle', 'c', 'cpp', 'h', 'hpp', 'go',
      'rs', 'vue', 'yml', 'yaml', 'toml', 'properties', 'sql', 'rb', 'php', 'swift', 'cfg', 'ini',
      'gitignore'].includes(this.extOf(name));
  }

  /**
   * 轻量语法高亮：单遍扫描，注释（块/行/#）/字符串（含转义）/数字/关键字/XML 标签
   * 分别着色（VSCode Dark+ 配色，对齐安卓版）。超出 HIGHLIGHT_MAX_CHARS 的部分
   * 保持默认色，控制 span 数量与内存。
   */
  private highlightSegments(code: string): TextSeg[] {
    const segs: TextSeg[] = [];
    const n = Math.min(code.length, HIGHLIGHT_MAX_CHARS);
    const KW = '#569CD6';
    const STR = '#CE9178';
    const CMT = '#6A9955';
    const NUM = '#B5CEA8';
    const TAG = '#4EC9B0';
    const KEYWORDS: string[] = ['package', 'import', 'public', 'private', 'protected', 'class',
      'interface', 'enum', 'static', 'final', 'void', 'int', 'long', 'boolean', 'double', 'float',
      'char', 'byte', 'if', 'else', 'for', 'while', 'return', 'new', 'this', 'super', 'extends',
      'implements', 'try', 'catch', 'finally', 'throw', 'throws', 'null', 'true', 'false', 'var',
      'const', 'let', 'function', 'export', 'default', 'async', 'await', 'typeof', 'instanceof',
      'switch', 'case', 'break', 'continue', 'do', 'in', 'of', 'def', 'elif', 'from', 'lambda',
      'pass', 'with', 'as', 'not', 'and', 'or', 'self', 'fun', 'val', 'when', 'struct', 'impl',
      'fn', 'match', 'use', 'mod', 'pub', 'nil', 'end', 'then', 'elseif', 'local', 'yield'];
    let i = 0;
    let plain = '';
    const flush = (): void => {
      if (plain.length > 0) {
        segs.push({ text: plain, color: $r('app.color.text_primary') });
        plain = '';
      }
    };
    while (i < n) {
      const c = code.charAt(i);
      // 块注释 /* */
      if (c === '/' && i + 1 < n && code.charAt(i + 1) === '*') {
        let end = code.indexOf('*/', i + 2);
        end = end < 0 ? n : Math.min(n, end + 2);
        flush();
        segs.push({ text: code.substring(i, end), color: CMT });
        i = end;
        continue;
      }
      // 行注释 // 或 #
      if ((c === '/' && i + 1 < n && code.charAt(i + 1) === '/') || c === '#') {
        let end = code.indexOf('\n', i);
        end = (end < 0 || end > n) ? n : end;
        flush();
        segs.push({ text: code.substring(i, end), color: CMT });
        i = end;
        continue;
      }
      // 字符串（含转义；模板串可跨行）
      if (c === '"' || c === '\'' || c === '`') {
        let j = i + 1;
        while (j < n) {
          const d = code.charAt(j);
          if (d === '\\') {
            j += 2;
            continue;
          }
          if (d === c || (d === '\n' && c !== '`')) {
            j++;
            break;
          }
          j++;
        }
        const end = Math.min(n, j);
        flush();
        segs.push({ text: code.substring(i, end), color: STR });
        i = end;
        continue;
      }
      // XML/HTML 标签：整个 <tag ...> 作为一个着色单元
      if (c === '<' && i + 1 < n && (/[a-zA-Z]/.test(code.charAt(i + 1))
        || code.charAt(i + 1) === '/' || code.charAt(i + 1) === '!')) {
        let gt = code.indexOf('>', i);
        if (gt < 0 || gt > n) {
          gt = n;
        }
        flush();
        segs.push({ text: code.substring(i, Math.min(gt + 1, n)), color: TAG });
        i = Math.min(gt + 1, n);
        continue;
      }
      // 数字
      if (/[0-9]/.test(c)) {
        let k = i;
        while (k < n && (/[0-9a-fA-FxX.]/.test(code.charAt(k)))) {
          k++;
        }
        flush();
        segs.push({ text: code.substring(i, k), color: NUM });
        i = k;
        continue;
      }
      // 标识符/关键字（注意孤立 '@' 时至少前进 1 位，避免死循环）
      if (/[a-zA-Z_@]/.test(c)) {
        let k = i;
        while (k < n && /[a-zA-Z0-9_]/.test(code.charAt(k))) {
          k++;
        }
        const word = k > i ? code.substring(i, k) : code.charAt(i);
        if (k > i && KEYWORDS.includes(word)) {
          flush();
          segs.push({ text: word, color: KW });
        } else {
          plain += word;
        }
        i = Math.max(k, i + 1);
        continue;
      }
      plain += c;
      i++;
    }
    flush();
    if (code.length > HIGHLIGHT_MAX_CHARS) {
      segs.push({ text: '\n…（内容过长，已截断）', color: $r('app.color.text_placeholder') });
    }
    return segs;
  }

  /** 预览层下载并分享 */
  private async previewDownload(): Promise<void> {
    if (this.previewEntry) {
      await this.downloadFile(this.previewEntry);
    }
  }

  /** 日期格式化（ISO → YYYY/MM/DD） */
  private formatDate(iso: string): string {
    if (!iso || iso.length < 10) {
      return '';
    }
    return iso.substring(0, 10).replace(/-/g, '/');
  }

  /** 文件类型徽标与颜色（对齐安卓版 FilesActivity：英文缩写 + 语言专属色；null = 使用矢量图标） */
  private typeBadge(name: string): [string, string] | null {
    const n = name.toLowerCase();
    const ext = this.extOf(n);
    if (n.startsWith('.git')) {
      return ['GIT', '#F0604D'];
    }
    if (['mp4', 'mov', 'avi', 'mkv', 'webm'].includes(ext)) {
      return ['影', '#8B5CF6'];
    }
    if (['mp3', 'wav', 'flac', 'aac'].includes(ext)) {
      return ['音', '#F59E0B'];
    }
    if (['ts', 'tsx'].includes(ext)) {
      return ['TS', '#3178C6'];
    }
    if (['js', 'jsx', 'mjs'].includes(ext)) {
      return ['JS', '#E8C44A'];
    }
    if (['md', 'markdown'].includes(ext)) {
      return ['MD', '#519ABA'];
    }
    if (ext === 'py') {
      return ['PY', '#3572A5'];
    }
    if (['html', 'htm'].includes(ext)) {
      return ['HTML', '#E44D26'];
    }
    if (ext === 'css') {
      return ['CSS', '#563D7C'];
    }
    if (ext === 'sh') {
      return ['SH', '#89E051'];
    }
    if (ext === 'java') {
      return ['JAVA', '#B07219'];
    }
    if (['json', 'json5', 'jsonc'].includes(ext)) {
      return ['JSON', '#CBCB41'];
    }
    if (ext === 'xml') {
      return ['XML', '#E37933'];
    }
    if (ext === 'pdf') {
      return ['PDF', '#F44336'];
    }
    if (['zip', 'gz', 'tar', '7z', 'rar'].includes(ext)) {
      return ['ZIP', '#9C27B0'];
    }
    if (['txt', 'log'].includes(ext)) {
      return ['TXT', '#9AA5B1'];
    }
    if (['doc', 'docx'].includes(ext)) {
      return ['W', '#1D4ED8'];
    }
    if (['xls', 'xlsx', 'csv'].includes(ext)) {
      return ['X', '#15803D'];
    }
    if (['ppt', 'pptx'].includes(ext)) {
      return ['P', '#C2410C'];
    }
    // 图片与未识别类型：对齐安卓版，使用矢量图标而非文字徽标
    return null;
  }

  /** 徽标文字（空串 = 该类型用图标展示） */
  private badgeText(name: string): string {
    const b = this.typeBadge(name);
    return b ? b[0] : '';
  }

  /** 徽标颜色（badgeText 为空串时无意义） */
  private badgeColor(name: string): string {
    const b = this.typeBadge(name);
    return b ? b[1] : '';
  }

  @Builder
  badgeIcon(entry: FsEntry, big: boolean): void {
    if (entry.isDir) {
      // 文件夹：对齐安卓版 ic_ft_folder（灰蓝 Material 矢量）
      Image($r('app.media.ic_ft_folder'))
        .width(big ? 64 : 44)
        .height(big ? 64 : 44)
        .objectFit(ImageFit.Contain);
    } else if (this.isImage(entry.name)) {
      // 图片：对齐安卓版 ic_ft_image（紫色矢量）
      Image($r('app.media.ic_ft_image'))
        .width(big ? 64 : 44)
        .height(big ? 64 : 44)
        .objectFit(ImageFit.Contain);
    } else if (this.badgeText(entry.name).length > 0) {
      // 代码/文本等：彩色文字徽标（语言色文字 + 19% 透明同色底）
      Column() {
        Text(this.badgeText(entry.name))
          .fontSize(this.badgeText(entry.name).length > 2 ? (big ? 13 : 9) : (big ? 18 : 13))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.badgeColor(entry.name));
      }
      .width(big ? 64 : 44)
      .height(big ? 64 : 44)
      .borderRadius(big ? 16 : 12)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.badgeColor(entry.name) + '30');
    } else {
      // 未识别类型：对齐安卓版 ic_ft_file（灰蓝带折角矢量）
      Image($r('app.media.ic_ft_file'))
        .width(big ? 64 : 44)
        .height(big ? 64 : 44)
        .objectFit(ImageFit.Contain);
    }
  }

  /** 顶栏（对齐鸿蒙文件管理）：返回/标题 + 多选、搜索；下接面包屑与排序/视图工具行 */
  @Builder
  titleBar(): void {
    Row({ space: 10 }) {
      // 返回：多选模式先退多选；根目录回上一页；子目录回上级
      Text('‹')
        .fontSize(22)
        .fontColor($r('app.color.text_primary'))
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor($r('app.color.card_bg'))
        .onClick(() => {
          if (this.multiSelect) {
            this.exitMultiSelect();
            return;
          }
          if (this.currentPath.length > 0) {
            const idx = this.currentPath.lastIndexOf('/');
            this.loadDir(idx > 0 ? this.currentPath.substring(0, idx) : '');
          } else {
            router.back();
          }
        });
      if (this.multiSelect) {
        Text(`已选 ${this.selectedPaths.size} 项`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Text('取消')
          .fontSize(15)
          .fontColor($r('app.color.accent_color'))
          .onClick(() => {
            this.exitMultiSelect();
          });
      } else {
        Text(this.dirName())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        // 多选入口（对应截图"多选"胶囊）
        Text('多选')
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .onClick(() => {
            this.multiSelect = true;
          });
        // 搜索入口（对应截图搜索圆钮）
        Text('⌕')
          .fontSize(20)
          .fontColor($r('app.color.text_primary'))
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .borderRadius(18)
          .backgroundColor($r('app.color.card_bg'))
          .onClick(() => {
            this.searchMode = !this.searchMode;
            if (!this.searchMode) {
              this.searchKey = '';
            }
          });
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 12, right: 12 });

    // 搜索框：客户端过滤当前目录（不动请求层）
    if (this.searchMode && !this.multiSelect) {
      Row({ space: 8 }) {
        TextInput({ text: this.searchKey, placeholder: '搜索当前目录' })
          .height(40)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_placeholder'))
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(10)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.searchKey = v;
          });
        Text('✕')
          .fontSize(15)
          .fontColor($r('app.color.text_secondary'))
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.searchMode = false;
            this.searchKey = '';
          });
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2, bottom: 6 });
    }

    // 面包屑（多选模式隐藏；home 图标回根目录，逐级路径段点击跳回该层）
    if (!this.multiSelect && this.currentPath.length > 0) {
      Row() {
        Scroll(this.crumbScroller) {
          Row({ space: 4 }) {
            Image($r('app.media.ic_ft_home'))
              .width(18)
              .height(18)
              .objectFit(ImageFit.Contain)
              .onClick(() => {
                this.loadDir('');
              });
            ForEach(this.crumbSegs(), (seg: CrumbSeg) => {
              Row({ space: 4 }) {
                Text('›')
                  .fontSize(11)
                  .fontColor($r('app.color.text_placeholder'));
                Text(seg.name)
                  .fontSize(11)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .onClick(() => {
                    this.loadDir(seg.path);
                  });
              }
              .alignItems(VerticalAlign.Center);
            }, (seg: CrumbSeg) => seg.path)
          }
          .alignItems(VerticalAlign.Center);
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .height(20)
        .onAppear(() => {
          this.crumbScroller.scrollEdge(Edge.End);
        });
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 4 });
    }

    // 工具行：排序下拉居中 + 视图切换靠右（多选模式隐藏）
    if (!this.multiSelect) {
      Row() {
        Text(`${SORT_LABELS[this.sortBy]} ▼`)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .onClick(() => {
            this.showSortMenu = !this.showSortMenu;
          });
        Text(this.viewMode === ViewMode.LIST ? '▦' : '☰')
          .fontSize(19)
          .fontColor($r('app.color.text_secondary'))
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.viewMode = this.viewMode === ViewMode.LIST ? ViewMode.GRID : ViewMode.LIST;
          });
      }
      .width('100%')
      .height(44)
      .padding({ left: 8, right: 8 });
    }
  }

  /** 当前目录名 */
  private dirName(): string {
    if (this.currentPath.length === 0) {
      return '工作空间';
    }
    const idx = this.currentPath.lastIndexOf('/');
    return idx >= 0 ? this.currentPath.substring(idx + 1) : this.currentPath;
  }

  /** 面包屑层级段（逐级路径，每段可点跳回该层） */
  private crumbSegs(): CrumbSeg[] {
    const segs: CrumbSeg[] = [];
    let prefix = '';
    for (const seg of this.currentPath.split('/')) {
      if (seg.length === 0) {
        continue;
      }
      prefix = prefix.length > 0 ? `${prefix}/${seg}` : seg;
      segs.push({ name: seg, path: prefix });
    }
    return segs;
  }

  @Builder
  sortMenu(): void {
    Column({ space: 0 }) {
      ForEach(SORT_LABELS, (label: string, idx: number) => {
        Row() {
          Text(label)
            .fontSize(15)
            .fontColor(this.sortBy === idx ? $r('app.color.accent_color') : $r('app.color.text_primary'));
          Blank();
          if (this.sortBy === idx) {
            Text('✓')
              .fontSize(15)
              .fontColor($r('app.color.accent_color'));
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 20, right: 20 })
        .onClick(() => {
          this.sortBy = idx as SortBy;
          this.showSortMenu = false;
          this.applySort();
        });
      }, (label: string) => label);
    }
    .width(200)
    .borderRadius(14)
    .backgroundColor($r('app.color.sheet_bg'))
    .position({ x: '62%', y: 160 })
    .shadow({ radius: 20, color: 'rgba(0,0,0,0.4)' });
  }

  /** 列表视图行（对齐鸿蒙文件管理：平铺无卡片，多选模式行首带勾选框） */
  @Builder
  listRow(entry: FsEntry): void {
    Row({ space: 12 }) {
      if (this.multiSelect) {
        Text(this.selectedPaths.has(entry.path) ? '✓' : '')
          .width(22)
          .height(22)
          .borderRadius(11)
          .fontSize(14)
          .textAlign(TextAlign.Center)
          .fontColor('#FFFFFF')
          .backgroundColor(this.selectedPaths.has(entry.path) ? $r('app.color.accent_color') : Color.Transparent)
          .border({
            width: 1.5,
            color: this.selectedPaths.has(entry.path) ? $r('app.color.accent_color') : $r('app.color.text_placeholder')
          });
      }
      this.badgeIcon(entry, false);
      Column({ space: 3 }) {
        Text(entry.name)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.formatDate(entry.modifiedAt) + (entry.isDir ? '' : ' · ' + this.formatSize(entry.size)))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'));
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      if (entry.isDir) {
        Text('›')
          .fontSize(20)
          .fontColor($r('app.color.text_placeholder'));
      } else if (this.downloading.has(entry.path)) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color($r('app.color.accent_color'));
      }
    }
    .width('100%')
    .height(72)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      if (this.multiSelect) {
        this.toggleSelect(entry.path);
        return;
      }
      if (entry.isDir) {
        this.loadDir(entry.path);
      } else if (this.isPreviewable(entry)) {
        this.previewHistory = []; // 从文件列表打开，清空跳转历史
        this.openPreview(entry);
      }
    });
  }

  /** 网格视图卡片 */
  @Builder
  gridCard(entry: FsEntry): void {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          this.badgeIcon(entry, true);
        }
        .width('100%')
        .height(88)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);

        if (this.downloading.has(entry.path)) {
          LoadingProgress()
            .width(24)
            .height(24)
            .color($r('app.color.accent_color'))
            .position({ x: '80%', y: 10 });
        }
      }
      .width('100%')
      .height(90);

      Text(entry.name)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Text(this.formatDate(entry.modifiedAt))
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
    }
    .padding(12)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .onClick(() => {
      if (entry.isDir) {
        this.loadDir(entry.path);
      } else if (this.isPreviewable(entry)) {
        this.previewHistory = []; // 从文件列表打开，清空跳转历史
        this.openPreview(entry);
      }
    });
  }

  /** 预览覆盖层：全屏，顶栏（关闭+文件名），中部内容区，底部操作栏（下载分享） */
  @Builder
  previewOverlay(): void {
    if (this.previewEntry !== null) {
      Column() {
        // 顶栏
        Row() {
          Text('‹')
            .fontSize(28)
            .fontColor($r('app.color.text_primary'))
            .width(44)
            .height(44)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.closePreview();
            });
          Text(this.previewEntry.name)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
          // HTML 专属：渲染/源码切换（对齐安卓版）
          if (this.isHtml(this.previewEntry.name) && !this.previewLoading && this.previewDataUri.length > 0) {
            Text('渲染')
              .fontSize(14)
              .fontWeight(this.previewShowSource ? FontWeight.Normal : FontWeight.Bold)
              .fontColor(this.previewShowSource ? $r('app.color.text_secondary') : $r('app.color.accent_color'))
              .padding({ left: 10, right: 6 })
              .onClick(() => {
                this.previewShowSource = false;
              });
            Text('源码')
              .fontSize(14)
              .fontWeight(this.previewShowSource ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.previewShowSource ? $r('app.color.accent_color') : $r('app.color.text_secondary'))
              .padding({ left: 6, right: 10 })
              .onClick(() => {
                this.previewShowSource = true;
              });
          }
          Text(this.formatSize(this.previewEntry.size))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .padding({ right: 16 });
        }
        .width('100%')
        .height(52);

        // 内容区
        if (this.previewLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.accent_color'));
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center);
        } else if (this.previewError) {
          Column({ space: 14 }) {
            Text('⚠️')
              .fontSize(32);
            Text(this.previewError)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 30, right: 30 })
              .textAlign(TextAlign.Center);
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center);
        } else if (this.previewPixelMap !== null) {
          // 图片预览
          Scroll() {
            Image(this.previewPixelMap)
              .objectFit(ImageFit.Contain)
              .width('100%');
          }
          .scrollBar(BarState.Auto)
          .width('100%')
          .layoutWeight(1);
        } else if (this.previewDataUri.length > 0) {
          if (this.previewShowSource) {
            // 源码视图（HTML 切换）
            this.previewSourceView();
          } else {
            // Markdown/HTML 渲染预览（Web 组件）
            Column() {
              Web({ src: this.previewDataUri, controller: this.previewWebController })
                .width('100%')
                .height('100%')
                .javaScriptAccess(true)
                .darkMode(WebDarkMode.Auto)
                .onControllerAttached(() => {
                  // 注册链接跳转桥：预览内 MD 相对链接 → openPreview 加载目标文件
                  try {
                    this.previewWebController.registerJavaScriptProxy(this, 'kimiPreviewLink', ['open']);
                  } catch (e) {
                    console.warn(`[Kimi][preview] 桥注册失败: ${(e as Error).message}`);
                  }
                })
                .onPageEnd(() => {
                  console.info('[Kimi][preview] Web 页面加载完成');
                })
                .onErrorReceive((event: OnErrorReceiveEvent) => {
                  if (event && event.request.isMainFrame()) {
                    console.error(`[Kimi][preview] Web 错误: ${event.error.getErrorInfo()}`);
                  }
                });
            }
            .width('100%')
            .layoutWeight(1);
          }
        } else if (this.previewLocalPath.length > 0) {
          // 视频/PDF：先用系统应用打开沙箱文件（离线预览），文本走上面的分支
          Column({ space: 14 }) {
            Text(this.previewEntry.name)
              .fontSize(16)
              .fontColor($r('app.color.text_primary'));
            Text('该类型使用系统应用打开')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'));
            Button('用系统应用打开')
              .height(42)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .backgroundColor($r('app.color.accent_color'))
              .borderRadius(10)
              .onClick(() => {
                const entry = this.previewEntry;
                if (entry !== null) {
                  this.shareFile(this.previewLocalPath, entry.name);
                }
              });
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center);
        } else if (this.previewText.length > 0 || this.previewSegs.length > 0) {
          // 源码/文本预览
          this.previewSourceView();
        }

        // 底部操作栏：下载并分享
        Row() {
          Button('下载 / 分享')
            .height(44)
            .fontSize(15)
            .fontColor('#FFFFFF')
            .backgroundColor($r('app.color.accent_color'))
            .borderRadius(12)
            .width('60%')
            .enabled(!this.downloading.has(this.previewEntry.path))
            .onClick(() => {
              this.previewDownload();
            });
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 10, bottom: 30 });
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.web_status_bg'))
      .padding({ top: this.statusBarHeight })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
    }
  }

  build(): void {
    Stack() {
      // 背景层：与网页标题栏/状态栏一致的颜色
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.web_status_bg'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);

      Column() {
        this.titleBar();

        if (this.showSortMenu) {
          this.sortMenu();
        }

        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.accent_color'));
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center);
        } else if (this.error) {
          Column({ space: 12 }) {
            Text('⚠️')
              .fontSize(32);
            Text(this.error)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 });
            Button('重试')
              .height(40)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .backgroundColor($r('app.color.accent_color'))
              .borderRadius(10)
              .onClick(() => {
                this.loadDir(this.currentPath);
              });
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center);
        } else if (this.sortedEntries.length === 0) {
          Column() {
            Text('空目录')
              .fontSize(14)
              .fontColor($r('app.color.text_placeholder'));
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center);
        } else if (this.viewMode === ViewMode.LIST) {
          List({ space: 0 }) {
            ForEach(this.sortedEntries, (entry: FsEntry) => {
              ListItem() {
                this.listRow(entry);
              }
            }, (entry: FsEntry) => entry.path);
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring);
        } else {
          // 网格视图：两列
          GridRow({ columns: 2, gutter: 10 }) {
            ForEach(this.sortedEntries, (entry: FsEntry) => {
              GridCol() {
                this.gridCard(entry);
              }
            }, (entry: FsEntry) => entry.path);
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 10, right: 10, top: 6 });
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.statusBarHeight })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);

      // 预览覆盖层（最上层）
      this.previewOverlay();
    }
    .width('100%')
    .height('100%')
    .onClick(() => {
      if (this.showSortMenu) {
        this.showSortMenu = false;
      }
    });
  }
}
