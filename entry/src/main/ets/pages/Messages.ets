/**
 * Messages.ets - 消息页。
 *
 * - 顶部 scope 筛选（全部/本租户/公开，分段按钮）+ 刷新；切换即重拉第一页。
 * - List 渲染：标题、正文摘要、topic、级别标签（info/warning/error 配色）、时间。
 * - SSE 实时订阅：message 事件去重后插入列表顶部；状态条展示实时连接状态。
 * - 右上菜单：退出登录（清会话回登录页）。
 * - 会话失效（401）：清会话并回登录页。
 */
import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { ApiClient, ApiError, MessageScope, SseClient, SseStateEvent } from '../Net';
import { SessionStore } from '../Session';
import { formatTime, Message, parseSavedUser, User } from '../Model';

/** 实时列表长度上限，防止长连接场景无限增长 */
const MAX_LIVE_MESSAGES: number = 500;

@Entry
@Component
struct Messages {
  @State messages: Message[] = [];
  @State scopeIndex: number = 0;
  @State connected: boolean = false;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State errorText: string = '';
  @State displayName: string = '';
  @State tenantName: string = '';
  @State hasMore: boolean = false;

  private api: ApiClient | null = null;
  private sse: SseClient | null = null;
  private nextCursor: string = '';
  private seenIds: Set<number> = new Set<number>();
  private myTenantId: number = 0;

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const session = SessionStore.load(context);
    if (session.baseUrl === '' || session.cookie === '') {
      router.replaceUrl({ url: 'pages/Index' }).catch(() => {
      });
      return;
    }
    let user: User | null = null;
    if (session.userJson !== '') {
      try {
        user = parseSavedUser(session.userJson);
      } catch (e) {
        user = null;
      }
    }
    this.displayName = user !== null && user.displayName !== '' ? user.displayName : session.email;
    this.tenantName = user !== null ? user.tenant.name : '';
    this.myTenantId = user !== null ? user.tenant.id : 0;

    const api = new ApiClient(session.baseUrl, session.cookie);
    this.api = api;
    this.setupStream(context, api, session.baseUrl);
    this.sse?.start();
    this.reload();
  }

  aboutToDisappear(): void {
    if (this.sse !== null) {
      this.sse.destroy();
      this.sse = null;
    }
  }

  // -----------------------------------------------------------------------
  // 数据加载
  // -----------------------------------------------------------------------

  private currentScope(): MessageScope {
    if (this.scopeIndex === 1) {
      return MessageScope.Own;
    }
    if (this.scopeIndex === 2) {
      return MessageScope.Public;
    }
    return MessageScope.All;
  }

  /** 重拉第一页（进入页面、切换筛选、手动刷新共用） */
  private async reload(): Promise<void> {
    const api = this.api;
    if (api === null || this.loading) {
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const page = await api.listMessages(this.currentScope(), '');
      this.messages = page.items;
      this.nextCursor = page.nextCursor;
      this.hasMore = page.nextCursor !== '';
      this.rebuildSeen();
    } catch (err) {
      const error = err as ApiError;
      if (error.status === 401) {
        this.sessionExpired();
      } else {
        this.errorText = this.friendlyError(error);
      }
    } finally {
      this.loading = false;
    }
  }

  /** 触底加载下一页（id 降序游标翻页） */
  private async loadMore(): Promise<void> {
    const api = this.api;
    if (api === null || this.loadingMore || this.loading || !this.hasMore) {
      return;
    }
    this.loadingMore = true;
    try {
      const cursor = this.nextCursor;
      const page = await api.listMessages(this.currentScope(), cursor);
      this.nextCursor = page.nextCursor;
      this.hasMore = page.nextCursor !== '';
      for (let i = 0; i < page.items.length; i++) {
        const item = page.items[i];
        if (!this.seenIds.has(item.id)) {
          this.seenIds.add(item.id);
          this.messages.push(item);
        }
      }
    } catch (err) {
      const error = err as ApiError;
      if (error.status === 401) {
        this.sessionExpired();
      } else {
        this.errorText = this.friendlyError(error);
      }
    } finally {
      this.loadingMore = false;
    }
  }

  private rebuildSeen(): void {
    const seen = new Set<number>();
    for (let i = 0; i < this.messages.length; i++) {
      seen.add(this.messages[i].id);
    }
    this.seenIds = seen;
  }

  // -----------------------------------------------------------------------
  // SSE 实时流
  // -----------------------------------------------------------------------

  private setupStream(context: common.UIAbilityContext, api: ApiClient, baseUrl: string): void {
    const client = new SseClient(baseUrl, (): string => api.getSessionCookie());
    client.onMessage = (message: Message): void => {
      this.handleLiveMessage(message);
    };
    client.onState = (state: SseStateEvent): void => {
      this.connected = state.connected;
    };
    client.onCookie = (cookie: string): void => {
      // 流响应头带回新 Cookie：更新内存与持久化，保证 12h 会话滚动续期
      api.setCookie(cookie);
      SessionStore.saveCookie(context, cookie);
    };
    client.onUnauthorized = (): void => {
      this.sessionExpired();
    };
    this.sse = client;
  }

  /** message 事件：按当前 scope 过滤、去重后插入列表顶部 */
  private handleLiveMessage(message: Message): void {
    if (!this.matchesScope(message) || this.seenIds.has(message.id)) {
      return;
    }
    this.seenIds.add(message.id);
    this.messages.unshift(message);
    while (this.messages.length > MAX_LIVE_MESSAGES) {
      const dropped = this.messages.pop();
      if (dropped === undefined) {
        break;
      }
      this.seenIds.delete(dropped.id);
    }
  }

  /** 历史列表由服务端按 scope 过滤；实时流为本人租户+公开，需在端侧按当前 scope 过滤 */
  private matchesScope(message: Message): boolean {
    if (this.scopeIndex === 1) {
      return message.tenantId === this.myTenantId;
    }
    if (this.scopeIndex === 2) {
      return message.isPublic;
    }
    return true;
  }

  // -----------------------------------------------------------------------
  // 会话与登出
  // -----------------------------------------------------------------------

  /** 会话失效：停流、清持久化、回登录页 */
  private sessionExpired(): void {
    if (this.sse !== null) {
      this.sse.destroy();
      this.sse = null;
    }
    const context = getContext(this) as common.UIAbilityContext;
    SessionStore.clear(context);
    this.showToast(this.res($r('app.string.session_expired')));
    router.replaceUrl({ url: 'pages/Index' }).catch(() => {
    });
  }

  private confirmLogout(): void {
    AlertDialog.show({
      title: $r('app.string.logout_confirm_title'),
      message: $r('app.string.logout_confirm_message'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: $r('app.string.action_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.action_logout'),
        fontColor: '#E84026',
        action: () => {
          this.logout();
        }
      }
    });
  }

  private logout(): void {
    if (this.sse !== null) {
      this.sse.destroy();
      this.sse = null;
    }
    const context = getContext(this) as common.UIAbilityContext;
    SessionStore.clear(context);
    router.replaceUrl({ url: 'pages/Index' }).catch(() => {
    });
  }

  // -----------------------------------------------------------------------
  // 展示辅助
  // -----------------------------------------------------------------------

  private res(resource: Resource): string {
    const context = getContext(this) as common.UIAbilityContext;
    return context.resourceManager.getStringSync(resource.id);
  }

  private showToast(text: string): void {
    promptAction.showToast({ message: text, duration: 2500 });
  }

  private friendlyError(error: ApiError): string {
    if (error.serverMessage !== '') {
      return error.serverMessage;
    }
    if (error.status === 0) {
      return this.res($r('app.string.err_network'));
    }
    if (error.status === 401) {
      return this.res($r('app.string.err_unauthorized'));
    }
    return this.res($r('app.string.err_server'));
  }

  private levelColor(level: string): string {
    if (level === 'warning') {
      return '#FF7D00';
    }
    if (level === 'error') {
      return '#E84026';
    }
    return '#165DFF';
  }

  private levelBackground(level: string): string {
    if (level === 'warning') {
      return '#FFF7E8';
    }
    if (level === 'error') {
      return '#FDECEC';
    }
    return '#E8F3FF';
  }

  private levelText(level: string): Resource {
    if (level === 'warning') {
      return $r('app.string.level_warning');
    }
    if (level === 'error') {
      return $r('app.string.level_error');
    }
    return $r('app.string.level_info');
  }

  private scopeTitle(index: number): Resource {
    if (index === 1) {
      return $r('app.string.scope_own');
    }
    if (index === 2) {
      return $r('app.string.scope_public');
    }
    return $r('app.string.scope_all');
  }

  private switchScope(index: number): void {
    if (this.scopeIndex === index || this.loading) {
      return;
    }
    this.scopeIndex = index;
    this.reload();
  }

  private menuItems(): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: $r('app.string.action_logout'),
        action: () => {
          this.confirmLogout();
        }
      }
    ];
    return items;
  }

  // -----------------------------------------------------------------------
  // 布局
  // -----------------------------------------------------------------------

  @Builder
  Header() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text($r('app.string.page_messages_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1D2129')
        if (this.subtitle() !== '') {
          Text(this.subtitle())
            .fontSize(12)
            .fontColor('#86909C')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Button($r('app.string.action_refresh'))
        .backgroundColor('#F2F3F5')
        .fontColor('#165DFF')
        .fontSize(13)
        .height(32)
        .enabled(!this.loading)
        .onClick(() => {
          this.reload();
        })
      Text('···')
        .fontSize(18)
        .fontColor('#4E5969')
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .borderRadius(16)
        .backgroundColor('#F2F3F5')
        .onClick(() => {
        })
        .bindMenu(this.menuItems())
    }
    .width('100%')
  }

  private subtitle(): string {
    if (this.tenantName !== '') {
      return `${this.displayName} · ${this.tenantName}`;
    }
    return this.displayName;
  }

  /** scope 分段筛选 */
  @Builder
  ScopeBar() {
    Row({ space: 0 }) {
      ForEach([0, 1, 2], (index: number) => {
        Text(this.scopeTitle(index))
          .fontSize(14)
          .fontWeight(this.scopeIndex === index ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.scopeIndex === index ? '#FFFFFF' : '#4E5969')
          .backgroundColor(this.scopeIndex === index ? '#165DFF' : '#F2F3F5')
          .height(32)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .borderRadius(16)
          .margin({ left: index === 0 ? 0 : 4, right: index === 2 ? 0 : 4 })
          .onClick(() => {
            this.switchScope(index);
          })
      }, (index: number) => index.toString())
    }
    .width('100%')
    .margin({ top: 10 })
  }

  /** 实时连接状态条 */
  @Builder
  StatusLine() {
    Row({ space: 6 }) {
      Circle({ width: 8, height: 8 })
        .fill(this.connected ? '#00B42A' : '#FF7D00')
      Text(this.connected ? $r('app.string.sse_connected') : $r('app.string.sse_connecting'))
        .fontSize(12)
        .fontColor(this.connected ? '#00B42A' : '#FF7D00')
      Blank()
      if (this.loading) {
        Text($r('app.string.list_loading'))
          .fontSize(12)
          .fontColor('#86909C')
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 4 })
  }

  @Builder
  ErrorLine() {
    if (this.errorText !== '') {
      Text(this.errorText)
        .fontSize(13)
        .fontColor('#E84026')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding(10)
        .borderRadius(8)
        .backgroundColor('#FDECEC')
        .margin({ bottom: 4 })
    }
  }

  @Builder
  MessageItem(message: Message) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(message.title === '' ? this.res($r('app.string.untitled')) : message.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1D2129')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.levelText(message.level))
          .fontSize(11)
          .fontColor(this.levelColor(message.level))
          .backgroundColor(this.levelBackground(message.level))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(10)
      }
      .width('100%')
      if (message.body !== '') {
        Text(message.body)
          .fontSize(14)
          .fontColor('#4E5969')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Row({ space: 6 }) {
        if (message.topic !== '') {
          Text(message.topic)
            .fontSize(11)
            .fontColor('#4E5969')
            .backgroundColor('#F2F3F5')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
        }
        if (message.isPublic) {
          Text($r('app.string.badge_public'))
            .fontSize(11)
            .fontColor('#00B42A')
            .backgroundColor('#E8FFEA')
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
        }
        Blank()
        Text(formatTime(message.createdAt))
          .fontSize(11)
          .fontColor('#86909C')
      }
      .width('100%')
    }
    .padding(14)
    .borderRadius(12)
    .backgroundColor('#FFFFFF')
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.Header()
      this.ScopeBar()
      this.StatusLine()
      this.ErrorLine()
      if (this.messages.length === 0 && !this.loading) {
        Column({ space: 10 }) {
          Text($r('app.string.list_empty'))
            .fontSize(15)
            .fontColor('#86909C')
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .width('100%')
      } else {
        List({ space: 8, initialIndex: 0 }) {
          ForEach(this.messages, (message: Message) => {
            ListItem() {
              this.MessageItem(message)
            }
          }, (message: Message) => message.id.toString())
          if (this.loadingMore) {
            ListItem() {
              Text($r('app.string.list_loading_more'))
                .fontSize(12)
                .fontColor('#86909C')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding(8)
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .onReachEnd(() => {
          this.loadMore();
        })
      }
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }
}
