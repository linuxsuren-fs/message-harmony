/**
 * Model.ets - 数据模型与 JSON 解析。
 *
 * 服务端契约（冻结）：
 * - 消息：{"id":1,"tenant_id":1,"topic":"","title":"","body":"","level":"info",
 *          "public":false,"created_at":"2026-11-14T10:00:00Z"}，level ∈ info|warning|error
 * - 分页：{"items":[...],"next_cursor":"123"}，id 降序，next_cursor 为 null 表示没有更多
 * - 登录：{"id":1,"email":"","display_name":"","role":"user","tenant":{"id":1,"name":""}}
 *
 * ArkTS 严格模式：JSON.parse 后统一 as Record<string, Object> 逐字段取值，
 * 不使用 any；字段缺失时回退到安全默认值。
 */

/** 租户 */
export interface Tenant {
  id: number;
  name: string;
}

/** 登录用户 */
export interface User {
  id: number;
  email: string;
  displayName: string;
  role: string;
  tenant: Tenant;
}

/** 一条消息 */
export interface Message {
  id: number;
  tenantId: number;
  topic: string;
  title: string;
  body: string;
  level: string; // info | warning | error
  isPublic: boolean;
  createdAt: string; // ISO 8601，如 2026-11-14T10:00:00Z
}

/** 一页消息 */
export interface MessagePage {
  items: Message[];
  nextCursor: string; // '' 表示没有更多
}

// ---------------------------------------------------------------------------
// 基础取值工具（仅接受 JSON 反序列化产物，缺失/类型不符时给默认值）
// ---------------------------------------------------------------------------

function asString(value: Object | undefined, fallback: string): string {
  return typeof value === 'string' ? value as string : fallback;
}

function asNumber(value: Object | undefined, fallback: number): number {
  return typeof value === 'number' ? value as number : fallback;
}

function asBoolean(value: Object | undefined, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value as boolean : fallback;
}

/** 将任意 level 归一为 info/warning/error 之一 */
export function normalizeLevel(level: string): string {
  if (level === 'warning' || level === 'error') {
    return level;
  }
  return 'info';
}

// ---------------------------------------------------------------------------
// 解析函数（JSON 文本 -> 模型；格式非法时抛异常，由调用方决定文案）
// ---------------------------------------------------------------------------

/** 解析租户对象；入参为空时返回占位租户 */
function parseTenant(raw: Object | undefined): Tenant {
  const tenant: Tenant = { id: 0, name: '' };
  if (raw === undefined || raw === null || typeof raw !== 'object') {
    return tenant;
  }
  const record = raw as Record<string, Object>;
  tenant.id = asNumber(record['id'], 0);
  tenant.name = asString(record['name'], '');
  return tenant;
}

/** 解析登录响应中的用户对象 */
export function parseUserObject(raw: Record<string, Object>): User {
  const user: User = {
    id: asNumber(raw['id'], 0),
    email: asString(raw['email'], ''),
    displayName: asString(raw['display_name'], ''),
    role: asString(raw['role'], 'user'),
    tenant: parseTenant(raw['tenant'])
  };
  return user;
}

/** 解析登录响应文本 */
export function parseUser(text: string): User {
  const raw = JSON.parse(text) as Record<string, Object>;
  return parseUserObject(raw);
}

/** 解析本地持久化的用户 JSON（应用侧 camelCase 字段，见 parseUserObject 的镜像） */
export function parseSavedUser(text: string): User {
  const raw = JSON.parse(text) as Record<string, Object>;
  const user: User = {
    id: asNumber(raw['id'], 0),
    email: asString(raw['email'], ''),
    displayName: asString(raw['displayName'], ''),
    role: asString(raw['role'], ''),
    tenant: parseTenant(raw['tenant'])
  };
  return user;
}

/** 解析单条消息对象 */
export function parseMessageObject(raw: Record<string, Object>): Message {
  const message: Message = {
    id: asNumber(raw['id'], 0),
    tenantId: asNumber(raw['tenant_id'], 0),
    topic: asString(raw['topic'], ''),
    title: asString(raw['title'], ''),
    body: asString(raw['body'], ''),
    level: normalizeLevel(asString(raw['level'], 'info')),
    isPublic: asBoolean(raw['public'], false),
    createdAt: asString(raw['created_at'], '')
  };
  return message;
}

/** 解析单条消息 JSON 文本（SSE data 用） */
export function parseMessage(text: string): Message {
  const raw = JSON.parse(text) as Record<string, Object>;
  return parseMessageObject(raw);
}

/** 解析消息分页响应：{"items":[...],"next_cursor":"..."|null} */
export function parseMessagePage(text: string): MessagePage {
  const raw = JSON.parse(text) as Record<string, Object>;
  const page: MessagePage = { items: [], nextCursor: '' };
  const items = raw['items'];
  if (Array.isArray(items)) {
    const array = items as Object[];
    for (let i = 0; i < array.length; i++) {
      const item = array[i];
      if (item === null || item === undefined || typeof item !== 'object') {
        continue;
      }
      page.items.push(parseMessageObject(item as Record<string, Object>));
    }
  }
  const cursor = raw['next_cursor'];
  if (cursor !== null && cursor !== undefined) {
    page.nextCursor = asString(cursor, '');
  }
  return page;
}

// ---------------------------------------------------------------------------
// 展示辅助
// ---------------------------------------------------------------------------

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** ISO 时间格式化为本地时间「YYYY-MM-DD HH:mm」；解析失败原样返回 */
export function formatTime(iso: string): string {
  if (iso === '') {
    return '';
  }
  const date = new Date(iso);
  if (isNaN(date.getTime())) {
    return iso;
  }
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} ` +
    `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}
