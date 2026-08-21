import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const adapterRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

// Cross-language adapter only. bin/fm-operational-input.sh owns the protocol,
// accepted kinds, marker bytes, and serialization grammar.
export function encodeFirstmateOperationalInput(root, kind, content) {
  return new Promise((resolveResult, reject) => {
    const requested = `${root}/bin/fm-operational-input.sh`;
    const script = existsSync(requested)
      ? requested
      : `${adapterRoot}/bin/fm-operational-input.sh`;
    const child = spawn(script, ["encode", kind], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    // An encoder that exits before reading its input breaks this pipe. Without
    // a listener that EPIPE is an unhandled 'error' event and takes the whole
    // host process down instead of rejecting this one call.
    child.stdin.on("error", () => {});
    child.on("close", (code) => {
      if (code === 0 && stdout) {
        resolveResult(stdout);
        return;
      }
      reject(new Error(stderr.trim() || `operational-input encoder exited ${code ?? "unknown"}`));
    });
    child.stdin.end(content);
  });
}
