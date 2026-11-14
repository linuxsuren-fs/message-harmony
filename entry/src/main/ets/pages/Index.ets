/**
 * Index.ets - 登录页。
 *
 * 流程：填写服务器地址/邮箱/密码 -> POST 登录 -> 持久化地址与会话 Cookie ->
 * router.pushUrl 进入消息页。失败时解析响应体 {"error":"..."} 并以 Toast 展示。
 * 启动时若存在未过期的持久化会话，则静默校验后直接进入消息页。
 */
import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { ApiClient, ApiError, MessageScope, normalizeBaseUrl } from '../Net';
import { SavedSession, SessionStore } from '../Session';

@Entry
@Component
struct Index {
  @State baseUrl: string = '';
  @State email: string = '';
  @State password: string = '';
  @State busy: boolean = false;
  @State message: string = '';

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const session = SessionStore.load(context);
    this.baseUrl = session.baseUrl;
    this.email = session.email;
    if (session.baseUrl !== '' && session.cookie !== '') {
      this.resumeSession(context, session);
    }
  }

  onPageShow(): void {
    // 从消息页退出登录返回：回填持久化数据并清空密码
    const context = getContext(this) as common.UIAbilityContext;
    const session = SessionStore.load(context);
    if (this.baseUrl === '') {
      this.baseUrl = session.baseUrl;
    }
    if (this.email === '') {
      this.email = session.email;
    }
    this.password = '';
    this.message = '';
    this.busy = false;
  }

  /** 静默恢复上次会话：仍有效则直接进入消息页，401 则清除过期会话 */
  private async resumeSession(context: common.UIAbilityContext, session: SavedSession): Promise<void> {
    this.busy = true;
    const api = new ApiClient(session.baseUrl, session.cookie);
    try {
      await api.listMessages(MessageScope.All, '');
      this.busy = false;
      router.replaceUrl({ url: 'pages/Messages' }).catch(() => {
      });
    } catch (err) {
      this.busy = false;
      const error = err as ApiError;
      if (error.status === 401) {
        SessionStore.clear(context);
        this.showToast(this.res($r('app.string.session_expired')));
      }
      // 网络等其它错误：留在登录页，由用户手动重试
    }
  }

  private canSubmit(): boolean {
    return !this.busy && this.baseUrl.trim() !== '' && this.email.trim() !== '' && this.password !== '';
  }

  private async doLogin(): Promise<void> {
    if (!this.canSubmit()) {
      return;
    }
    const baseUrl = normalizeBaseUrl(this.baseUrl);
    if (baseUrl === '') {
      return;
    }
    this.busy = true;
    this.message = '';
    const api = new ApiClient(baseUrl, '');
    try {
      const result = await api.login(this.email.trim(), this.password);
      const context = getContext(this) as common.UIAbilityContext;
      const saved: SavedSession = {
        baseUrl: baseUrl,
        email: this.email.trim(),
        cookie: result.cookie,
        userJson: JSON.stringify(result.user)
      };
      SessionStore.save(context, saved);
      this.showToast(this.res($r('app.string.login_success')));
      router.pushUrl({ url: 'pages/Messages' }).catch(() => {
      });
    } catch (err) {
      this.message = this.friendlyError(err as ApiError);
      this.showToast(this.message);
    } finally {
      this.busy = false;
    }
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

  /** 服务端 error 字段优先，其次按状态码映射友好文案 */
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

  @Builder
  BrandHeader() {
    Column({ space: 6 }) {
      Text($r('app.string.app_name'))
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1D2129')
      Text($r('app.string.page_login_title'))
        .fontSize(14)
        .fontColor('#86909C')
    }
    .margin({ top: 36, bottom: 28 })
  }

  @Builder
  FormCard() {
    Column({ space: 14 }) {
      Text($r('app.string.label_server_address'))
        .fontSize(14)
        .fontColor('#4E5969')
      TextInput({ text: this.baseUrl, placeholder: $r('app.string.hint_server_address') })
        .onChange((value: string) => {
          this.baseUrl = value;
        })
      Text($r('app.string.label_email'))
        .fontSize(14)
        .fontColor('#4E5969')
      TextInput({ text: this.email, placeholder: $r('app.string.hint_email') })
        .type(InputType.Email)
        .onChange((value: string) => {
          this.email = value;
        })
      Text($r('app.string.label_password'))
        .fontSize(14)
        .fontColor('#4E5969')
      TextInput({ text: this.password, placeholder: $r('app.string.label_password') })
        .type(InputType.Password)
        .onChange((value: string) => {
          this.password = value;
        })
      Button($r('app.string.action_login'))
        .width('100%')
        .margin({ top: 8 })
        .enabled(this.canSubmit())
        .onClick(() => {
          this.doLogin();
        })
    }
    .padding(20)
    .borderRadius(16)
    .backgroundColor('#FFFFFF')
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.BrandHeader()
      this.FormCard()
      if (this.message !== '') {
        Text(this.message)
          .fontSize(13)
          .fontColor('#E84026')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 12 })
      }
      Blank()
    }
    .padding(20)
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
