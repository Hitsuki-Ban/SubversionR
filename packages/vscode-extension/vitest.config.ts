import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/**/*.test.ts"],
    exclude: ["target/**", "dist/**", "node_modules/**"],
  },
});
