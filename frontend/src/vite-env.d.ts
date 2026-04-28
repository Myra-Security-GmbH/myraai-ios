/// <reference types="vite/client" />

interface AndroidBridge {
  notifyScrollTop(scrolled: boolean): void;
  hapticFeedback(type: string): void;
  share(text: string, url: string): void;
  copyToClipboard(text: string): void;
  getDeviceToken?(callbackName: string): void;
  requestNotificationPermission?(callbackName: string): void;
  getDeviceContext?(callbackName: string): void;
}

declare interface Window {
  Android?: AndroidBridge;
  __myraApnsToken?: string;
  [key: string]: unknown;
}

interface ImportMetaEnv {
  readonly VITE_ADMIN_URL?: string;
  readonly VITE_AUTH_URL?: string;
  readonly VITE_GATEWAY_URL?: string;
  readonly VITE_DOCS_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
