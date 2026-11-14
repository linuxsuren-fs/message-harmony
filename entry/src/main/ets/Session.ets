/**
 * Session.ets - 服务端地址与登录态持久化（@ohos.data.preferences）。
 *
 * 持久化内容：
 * - server.base_url   服务器地址（如 https://message.example.com）
 * - user.email        上次登录邮箱（便于回填）
 * - session.cookie    mh_session Cookie（服务端 12 小时有效期）
 * - session.user      登录用户 JSON（展示用，随 Cookie 一起失效）
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'message_hub';
const KEY_BASE_URL: string = 'server.base_url';
const KEY_EMAIL: string = 'user.email';
const KEY_COOKIE: string = 'session.cookie';
const KEY_USER: string = 'session.user';

/** 持久化的会话快照 */
export interface SavedSession {
  baseUrl: string;
  email: string;
  cookie: string;
  userJson: string;
}

export class SessionStore {
  private static store(context: common.UIAbilityContext): preferences.Preferences {
    const options: preferences.Options = { name: STORE_NAME };
    return preferences.getPreferencesSync(context, options);
  }

  static load(context: common.UIAbilityContext): SavedSession {
    const data = SessionStore.store(context);
    const session: SavedSession = {
      baseUrl: data.getSync(KEY_BASE_URL, '') as string,
      email: data.getSync(KEY_EMAIL, '') as string,
      cookie: data.getSync(KEY_COOKIE, '') as string,
      userJson: data.getSync(KEY_USER, '') as string
    };
    return session;
  }

  static save(context: common.UIAbilityContext, session: SavedSession): void {
    const data = SessionStore.store(context);
    data.putSync(KEY_BASE_URL, session.baseUrl);
    data.putSync(KEY_EMAIL, session.email);
    data.putSync(KEY_COOKIE, session.cookie);
    data.putSync(KEY_USER, session.userJson);
    data.flush();
  }

  /** 仅更新 Cookie（SSE 续期回写时使用） */
  static saveCookie(context: common.UIAbilityContext, cookie: string): void {
    const data = SessionStore.store(context);
    data.putSync(KEY_COOKIE, cookie);
    data.flush();
  }

  /** 清空登录态（退出登录 / 会话失效） */
  static clear(context: common.UIAbilityContext): void {
    const data = SessionStore.store(context);
    data.deleteSync(KEY_COOKIE);
    data.deleteSync(KEY_USER);
    data.flush();
  }
}
