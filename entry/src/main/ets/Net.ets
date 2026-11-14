/**
 * Net.ets - 网络层：REST 封装（ApiClient）与 SSE 实时订阅（SseClient）。
 *
 * REST：
 * - POST /api/v1/auth/login 登录，从响应头 Set-Cookie 抓取 mh_session，
 *   Cookie 仅保存在内存/Preferences，后续请求手动携带 Cookie 头。
 * - GET  /api/v1/messages?limit=&cursor=&scope= 拉取分页消息。
 * - 任何非 2xx 响应体为 {"error":"人类可读信息"}，统一转为 ApiError。
 *
 * SSE（GET /api/v1/stream）：
 * - http.createHttp() + requestInStream；
 *   on('headersReceive') 抓流响应里的 Set-Cookie（会话续期）；
 *   on('dataReceive') 把 Uint8Array 追加进字节缓冲，按 \n\n（兼容 \r\n\r\n）
 *   分帧后逐行解析 event:/data:；heartbeat 帧忽略；message 帧回调上层。
 * - 断线指数退避重连：1s、2s、4s … 上限 60s；心跳约 20s 一次，
 *   超过 75s 无任何数据则视为连接僵死并强制重连。
 * - destroy() 供页面 aboutToDisappear 调用，释放连接与定时器。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Message, MessagePage, parseMessageObject, parseMessagePage, parseUserObject, User } from './Model';

const CONNECT_TIMEOUT_MS: number = 10000;
const READ_TIMEOUT_MS: number = 15000;
const PAGE_LIMIT: number = 50;

const SSE_RETRY_BASE_MS: number = 1000;
const SSE_RETRY_MAX_MS: number = 60000;
const SSE_IDLE_TIMEOUT_MS: number = 75000;
const SSE_WATCHDOG_TICK_MS: number = 15000;

/** 消息范围（对应 GET /api/v1/messages 的 scope 参数） */
export enum MessageScope {
  All = 'all',
  Own = 'own',
  Public = 'public'
}

/** 登录请求体 */
interface LoginRequestBody {
  email: string;
  password: string;
}

/** 登录结果 */
export interface LoginResult {
  user: User;
  cookie: string;
}

/**
 * API 错误：
 * - status：HTTP 状态码，0 表示网络层错误；
 * - serverMessage：服务端 {"error":"..."} 原文，可能为空。
 */
export class ApiError extends Error {
  readonly status: number;
  readonly serverMessage: string;

  constructor(message: string, status: number, serverMessage: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.serverMessage = serverMessage;
  }
}

/** 规范化服务器地址：补协议、去末尾斜杠 */
export function normalizeBaseUrl(input: string): string {
  let url = input.trim();
  if (url === '') {
    return '';
  }
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    url = `http://${url}`;
  }
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

/** 从 Set-Cookie 值里挑出 mh_session=xxx（其余属性丢弃） */
function pickSessionCookie(raw: string): string {
  const marker = 'mh_session=';
  const start = raw.indexOf(marker);
  if (start < 0) {
    return '';
  }
  let value = raw.substring(start + marker.length);
  const end = value.indexOf(';');
  if (end >= 0) {
    value = value.substring(0, end);
  }
  return value === '' ? '' : `${marker}${value}`;
}

/** 从响应头对象提取 mh_session Cookie（键大小写不敏感，值可为 string 或数组） */
export function extractSessionCookie(headers: Record<string, Object>): string {
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    if (key.toLowerCase() !== 'set-cookie') {
      continue;
    }
    const value = headers[key];
    if (typeof value === 'string') {
      const cookie = pickSessionCookie(value as string);
      if (cookie !== '') {
        return cookie;
      }
    } else if (Array.isArray(value)) {
      const list = value as Object[];
      for (let j = 0; j < list.length; j++) {
        const item = list[j];
        if (typeof item === 'string') {
          const cookie = pickSessionCookie(item as string);
          if (cookie !== '') {
            return cookie;
          }
        }
      }
    }
  }
  return '';
}

/** 从非 2xx 响应体 {"error":"..."} 提取服务端文案 */
function extractServerError(text: string): string {
  try {
    const raw = JSON.parse(text) as Record<string, Object>;
    const message = raw['error'];
    if (typeof message === 'string' && (message as string) !== '') {
      return message as string;
    }
  } catch (e) {
    // 非 JSON 响应体，忽略
  }
  return '';
}

/** 网络层异常统一转为 ApiError（status=0） */
function toNetworkError(error: BusinessError): ApiError {
  return new ApiError(`${error.code} ${error.message}`, 0, '');
}

/**
 * REST 客户端。无状态化设计：每次请求独立连接；Cookie 保存在实例内。
 */
export class ApiClient {
  private baseUrl: string;
  private cookie: string;

  constructor(baseUrl: string, cookie: string) {
    this.baseUrl = normalizeBaseUrl(baseUrl);
    this.cookie = cookie;
  }

  /** SSE 续期拿到新 Cookie 后回写 */
  setCookie(cookie: string): void {
    if (cookie !== '') {
      this.cookie = cookie;
    }
  }

  getSessionCookie(): string {
    return this.cookie;
  }

  /** 登录；成功后实例内 Cookie 同步更新 */
  login(email: string, password: string): Promise<LoginResult> {
    const url = `${this.baseUrl}/api/v1/auth/login`;
    const body: LoginRequestBody = { email: email, password: password };
    return new Promise<LoginResult>((resolve, reject) => {
      const client = http.createHttp();
      const header: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      };
      if (this.cookie !== '') {
        header['Cookie'] = this.cookie;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: JSON.stringify(body),
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      };
      client.request(url, options)
        .then((response: http.HttpResponse) => {
          client.destroy();
          const status = response.responseCode;
          const text = response.result as string;
          if (status !== 200) {
            reject(new ApiError('登录失败', status, extractServerError(text)));
            return;
          }
          const cookie = extractSessionCookie(response.header as Record<string, Object>);
          if (cookie === '') {
            reject(new ApiError('登录响应缺少会话 Cookie', status, ''));
            return;
          }
          let user: User;
          try {
            user = parseUserObject(JSON.parse(text) as Record<string, Object>);
          } catch (e) {
            reject(new ApiError('登录响应解析失败', status, ''));
            return;
          }
          this.cookie = cookie;
          const result: LoginResult = { user: user, cookie: cookie };
          resolve(result);
        })
        .catch((error: BusinessError) => {
          client.destroy();
          reject(toNetworkError(error));
        });
    });
  }

  /** 分页拉取消息；cursor 传空串取第一页 */
  listMessages(scope: MessageScope, cursor: string): Promise<MessagePage> {
    const url = `${this.baseUrl}/api/v1/messages?limit=${PAGE_LIMIT}` +
      `&cursor=${encodeURIComponent(cursor)}&scope=${scope}`;
    return new Promise<MessagePage>((resolve, reject) => {
      const client = http.createHttp();
      const header: Record<string, string> = { 'Accept': 'application/json' };
      if (this.cookie !== '') {
        header['Cookie'] = this.cookie;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      };
      client.request(url, options)
        .then((response: http.HttpResponse) => {
          client.destroy();
          const status = response.responseCode;
          const text = response.result as string;
          if (status !== 200) {
            reject(new ApiError('拉取消息失败', status, extractServerError(text)));
            return;
          }
          try {
            resolve(parseMessagePage(text));
          } catch (e) {
            reject(new ApiError('消息响应解析失败', status, ''));
          }
        })
        .catch((error: BusinessError) => {
          client.destroy();
          reject(toNetworkError(error));
        });
    });
  }
}

/** SSE 连接状态通知 */
export interface SseStateEvent {
  connected: boolean;
  detail: string;
}

/** 帧在字节缓冲中的结束位置 */
interface FramePos {
  start: number; // -1 表示未找到完整帧
  length: number;
}

/**
 * SSE 实时订阅客户端。一次 start() 独占一条流，直到 destroy()。
 * 事件到达顺序与页面渲染解耦：仅做解析与回调。
 */
export class SseClient {
  private baseUrl: string;
  private cookieProvider: () => string;

  /** 收到 message 事件 */
  onMessage: (message: Message) => void = () => {
  };
  /** 连接状态变化（detail 供日志） */
  onState: (state: SseStateEvent) => void = () => {
  };
  /** 流响应头带回新 Cookie（会话续期） */
  onCookie: (cookie: string) => void = () => {
  };
  /** 流返回 401：会话失效，页面应回登录页 */
  onUnauthorized: () => void = () => {
  };

  private client: http.HttpRequest | null = null;
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private buffer: Uint8Array = new Uint8Array(0);
  private attempts: number = 0;
  private reconnectTimer: number = -1;
  private watchdogTimer: number = -1;
  private lastDataAt: number = 0;
  private destroyed: boolean = false;

  constructor(baseUrl: string, cookieProvider: () => string) {
    this.baseUrl = normalizeBaseUrl(baseUrl);
    this.cookieProvider = cookieProvider;
  }

  /** 启动订阅（幂等：已启动则忽略） */
  start(): void {
    if (this.destroyed || this.watchdogTimer >= 0) {
      return;
    }
    this.startWatchdog();
    this.connect();
  }

  /** 停止订阅并释放资源（页面 aboutToDisappear 调用） */
  destroy(): void {
    this.destroyed = true;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    if (this.watchdogTimer >= 0) {
      clearInterval(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
    this.closeClient();
  }

  // -----------------------------------------------------------------------
  // 内部实现
  // -----------------------------------------------------------------------

  private connect(): void {
    if (this.destroyed) {
      return;
    }
    this.closeClient();
    const client = http.createHttp();
    this.client = client;
    client.on('headersReceive', (header: Object) => {
      const cookie = extractSessionCookie(header as Record<string, Object>);
      if (cookie !== '') {
        this.onCookie(cookie);
      }
    });
    client.on('dataReceive', (chunk: ArrayBuffer) => {
      this.lastDataAt = Date.now();
      this.appendChunk(new Uint8Array(chunk));
      this.drainFrames();
    });
    client.on('dataEnd', () => {
      // 服务端关闭流（心跳间隔远小于该事件，视为断线）
      this.scheduleReconnect('stream closed');
    });
    const header: Record<string, string> = {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache'
    };
    const cookie = this.cookieProvider();
    if (cookie !== '') {
      header['Cookie'] = cookie;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: CONNECT_TIMEOUT_MS
    };
    client.requestInStream(`${this.baseUrl}/api/v1/stream`, options)
      .then((code: number) => {
        if (this.destroyed) {
          return;
        }
        if (code === 401) {
          this.onUnauthorized();
          this.destroy();
          return;
        }
        if (code >= 200 && code < 300) {
          this.attempts = 0;
          this.notifyState(true, 'connected');
          return;
        }
        this.scheduleReconnect(`http ${code}`);
      })
      .catch((error: BusinessError) => {
        if (this.destroyed) {
          return;
        }
        this.scheduleReconnect(`${error.code} ${error.message}`);
      });
  }

  private closeClient(): void {
    if (this.client !== null) {
      this.client.off('headersReceive');
      this.client.off('dataReceive');
      this.client.off('dataEnd');
      this.client.destroy();
      this.client = null;
    }
    this.buffer = new Uint8Array(0);
  }

  /** 指数退避：1s、2s、4s…上限 60s；连接成功后清零 */
  private scheduleReconnect(reason: string): void {
    if (this.destroyed) {
      return;
    }
    this.notifyState(false, reason);
    this.closeClient();
    const delay = Math.min(SSE_RETRY_BASE_MS * Math.pow(2, this.attempts), SSE_RETRY_MAX_MS);
    this.attempts = Math.min(this.attempts + 1, 6);
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.connect();
    }, delay);
  }

  /** 心跳看门狗：约 20s 一次心跳，超过 75s 无数据判定连接僵死 */
  private startWatchdog(): void {
    this.lastDataAt = Date.now();
    this.watchdogTimer = setInterval(() => {
      if (this.destroyed) {
        return;
      }
      if (Date.now() - this.lastDataAt > SSE_IDLE_TIMEOUT_MS) {
        this.scheduleReconnect('heartbeat timeout');
      }
    }, SSE_WATCHDOG_TICK_MS);
  }

  private notifyState(connected: boolean, detail: string): void {
    const event: SseStateEvent = { connected: connected, detail: detail };
    this.onState(event);
  }

  private appendChunk(chunk: Uint8Array): void {
    const merged = new Uint8Array(this.buffer.length + chunk.length);
    merged.set(this.buffer, 0);
    merged.set(chunk, this.buffer.length);
    this.buffer = merged;
  }

  /** 循环切出完整帧交给解析 */
  private drainFrames(): void {
    while (true) {
      const pos = this.findFrameSeparator(this.buffer);
      if (pos.start < 0) {
        return;
      }
      const frame = this.buffer.subarray(0, pos.start);
      this.buffer = this.buffer.subarray(pos.start + pos.length);
      this.handleFrame(frame);
    }
  }

  /** 查找帧分隔：\n\n 或 \r\n\r\n（跨过 \n 后剩余的 \r\n） */
  private findFrameSeparator(buffer: Uint8Array): FramePos {
    for (let i = 0; i + 1 < buffer.length; i++) {
      if (buffer[i] !== 10) {
        continue;
      }
      if (buffer[i + 1] === 10) {
        return { start: i, length: 2 };
      }
      if (buffer[i + 1] === 13 && i + 2 < buffer.length && buffer[i + 2] === 10) {
        return { start: i, length: 3 };
      }
    }
    const pos: FramePos = { start: -1, length: 0 };
    return pos;
  }

  /** 解析一帧：event:/data:/retry: 行；heartbeat 忽略；message 回调上层 */
  private handleFrame(bytes: Uint8Array): void {
    const text = this.decoder.decodeToString(bytes);
    const lines = text.split('\n');
    let event = 'message'; // SSE 默认事件名
    const dataLines: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      let line = lines[i];
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line === '' || line.startsWith(':')) {
        continue; // 空行与注释行
      }
      const colon = line.indexOf(':');
      const field = colon < 0 ? line : line.substring(0, colon);
      let value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
      if (field === 'event') {
        event = value;
      } else if (field === 'data') {
        dataLines.push(value);
      }
      // retry: 行仅是服务端建议，客户端按自身退避策略执行，忽略
    }
    if (dataLines.length === 0) {
      return;
    }
    if (event === 'heartbeat') {
      return;
    }
    if (event !== 'message') {
      return;
    }
    try {
      const raw = JSON.parse(dataLines.join('\n')) as Record<string, Object>;
      this.onMessage(parseMessageObject(raw));
    } catch (e) {
      // 单帧损坏不影响后续帧
    }
  }
}
