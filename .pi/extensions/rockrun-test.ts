/**
 * Rockrun test runner — pi extension.
 *
 * Registers the `rockrun_test` tool: compiles the Nim game and runs its
 * in-engine scripted startup test, then summarizes the verdicts and
 * points at the newest screenshots written during the run.
 *
 * Install: copy to ~/.pi/agent/extensions/ (global) or .pi/extensions/
 * (project-local), then /reload in pi.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { existsSync, readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

function findProjectRoot(hint?: string): string {
  let dir = hint ? resolve(hint) : process.cwd();
  for (;;) {
    if (
      existsSync(join(dir, "config.nims")) &&
      existsSync(join(dir, "data", "config", "rockrun.ini"))
    ) {
      return dir;
    }
    const parent = resolve(dir, "..");
    if (parent === dir) return "";
    dir = parent;
  }
}

function tail(text: string, lines: number): string {
  const all = text.split("\n");
  return all.slice(Math.max(0, all.length - lines)).join("\n");
}

function newestScreenshots(cwd: string, count: number): string[] {
  const dir = join(cwd, "screenshots");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".png"))
    .map((f) => ({ path: join(dir, f), mtime: statSync(join(dir, f)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime)
    .slice(0, count)
    .map((e) => e.path);
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "rockrun_test",
    label: "Rockrun test",
    description:
      "Builds the Rockrun game (nim c -o:rockrun src/rockrun.nim) and runs its in-engine scripted startup test (./rockrun -c test.ini --startup-test true). Reports compile errors, the 'config/engine/completion checks passed' verdicts, any 'Rockrun test failed' lines, and the paths of the newest screenshots written during the run. Use after changing Nim sources, ORX config or level data.",
    promptSnippet: "rockrun_test: build the game and run the in-engine startup test",
    promptGuidelines: [
      "After changing rockrun Nim sources, data/config or tools/genlevels.py, run rockrun_test and make sure all checks pass.",
      "Never run the rockrun binary without -c test.ini (VSync stalls in automated environments) — rockrun_test handles this correctly.",
    ],
    parameters: Type.Object({
      build: Type.Optional(
        Type.Boolean({ description: "Compile first (default true)" }),
      ),
      cwd: Type.Optional(
        Type.String({
          description:
            "Rockrun project directory (auto-detected by walking up from the current directory)",
        }),
      ),
      timeoutSeconds: Type.Optional(
        Type.Number({ description: "Per-command timeout in seconds (default 300)" }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate, _ctx) {
      const cwd = findProjectRoot(params.cwd);
      if (!cwd) {
        const text =
          "Could not locate the rockrun project: no config.nims + data/config/rockrun.ini found walking up from " +
          (params.cwd ?? process.cwd());
        return { content: [{ type: "text", text }], details: { ok: false, stage: "locate" } };
      }
      const timeoutMs = (params.timeoutSeconds ?? 300) * 1000;
      const out: string[] = [];

      if (params.build !== false) {
        out.push("$ nim c -o:rockrun src/rockrun.nim");
        const build = await pi.exec(
          "nim",
          ["c", "-o:rockrun", "src/rockrun.nim"],
          { cwd, signal, timeout: timeoutMs },
        );
        const buildLog = (build.stdout + build.stderr).trim();
        if (build.code !== 0) {
          return {
            content: [
              {
                type: "text",
                text: `BUILD FAILED (exit ${build.code})\n\n${tail(buildLog, 60)}`,
              },
            ],
            details: { ok: false, stage: "build", code: build.code, log: tail(buildLog, 300) },
          };
        }
        out.push("build ok");
      }

      out.push("$ ./rockrun -c test.ini --startup-test true");
      const run = await pi.exec(
        "./rockrun",
        ["-c", "test.ini", "--startup-test", "true"],
        { cwd, signal, timeout: timeoutMs },
      );
      const log = (run.stdout + run.stderr).replace(/\x1b\[[0-9;]*m/g, "");
      const checks = {
        config: log.includes("Rockrun config checks passed"),
        engine: log.includes("Rockrun engine checks passed"),
        completion: log.includes("Rockrun completion checks passed"),
      };
      const failures = log
        .split("\n")
        .filter((l) => l.includes("Rockrun test failed:"));
      const screenshots = newestScreenshots(cwd, 6);
      const ok =
        run.code === 0 &&
        checks.config &&
        checks.engine &&
        checks.completion &&
        failures.length === 0;

      out.push(`test exit ${run.code}`);
      out.push(
        `checks: config=${checks.config} engine=${checks.engine} completion=${checks.completion}`,
      );
      out.push(`failures: ${failures.length}`);
      if (failures.length > 0) out.push(...failures);
      if (screenshots.length > 0) {
        out.push("newest screenshots:", ...screenshots.map((p) => "  " + p));
      }
      if (!ok) {
        out.push("", "--- last log lines ---", tail(log, 40));
      }
      return {
        content: [{ type: "text", text: out.join("\n") }],
        details: {
          ok,
          stage: "test",
          code: run.code,
          checks,
          failures,
          screenshots,
          log: tail(log, 200),
        },
      };
    },
  });
}
