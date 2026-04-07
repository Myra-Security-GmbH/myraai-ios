import * as path from "path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

/// <reference types="vitest" />

export default defineConfig({
  test: {
    environment: "jsdom",
    setupFiles: ["./src/setupTests.ts"],
    globals: true,
    include: ["src/**/*.test.{ts,tsx}"],
    css: false,
    coverage: {
      provider: "v8",
      reporter: ["text", "html"],
      include: ["src/**/*.{ts,tsx}"],
      exclude: ["src/**/*.test.{ts,tsx}", "src/main.tsx", "src/setupTests.ts"],
      reportsDirectory: "./coverage",
    },
  },
  server: {
    port: 5173,
    host: true,
    proxy: {
      "/admin": {
        target: "http://127.0.0.1:8081",
        changeOrigin: true,
      },
      "/share/": {
        target: "http://127.0.0.1:8081",
        changeOrigin: true,
      },
      "/v1": {
        target: "http://127.0.0.1:8081",
        changeOrigin: true,
      },
    },
  },
  plugins: [react()],
  resolve: {
    dedupe: ["react", "react-dom"],
    alias: {
      src: path.resolve(__dirname, "src"),
    },
  },
  css: {
    preprocessorOptions: {
      scss: {
        // node_modules is symlinked to myra-auto-captcha/node_modules
        loadPaths: [path.resolve(__dirname, "node_modules")],
      },
    },
  },
});
