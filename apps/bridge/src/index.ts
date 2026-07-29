import "dotenv/config";
import { runCli } from "./cli.js";

try {
  await runCli(process.argv.slice(2));
} catch (error) {
  console.error(`RelayCode: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
}
