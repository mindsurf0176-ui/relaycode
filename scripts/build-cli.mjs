import { chmodSync, mkdirSync } from "node:fs";
import { build } from "esbuild";

mkdirSync("dist", { recursive: true });

await build({
  entryPoints: ["apps/bridge/src/index.ts"],
  outfile: "dist/relaycode",
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node20",
  banner: {
    js: [
      "#!/usr/bin/env node",
      "import { createRequire as __relayCodeCreateRequire } from 'node:module';",
      "const require = __relayCodeCreateRequire(import.meta.url);",
    ].join("\n"),
  },
  legalComments: "none",
});

chmodSync("dist/relaycode", 0o755);
console.log("Built dist/relaycode.");
