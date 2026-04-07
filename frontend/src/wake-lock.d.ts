// Ambient declarations for the Screen Wake Lock API (W3C spec).
// TypeScript's built-in DOM lib does not yet include these types.

interface WakeLockSentinel extends EventTarget {
  readonly type: "screen";
  readonly released: boolean;
  release(): Promise<void>;
  onrelease: ((this: WakeLockSentinel, ev: Event) => unknown) | null;
}

interface WakeLock {
  request(type: "screen"): Promise<WakeLockSentinel>;
}

interface Navigator {
  readonly wakeLock: WakeLock;
}
