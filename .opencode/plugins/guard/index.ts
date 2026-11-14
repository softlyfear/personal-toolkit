import { spawn } from "node:child_process"
import path from "node:path"
import { Plugin } from "@opencode/plugin"

const GUARD_TIMEOUT_MS = 15 * 60 * 1000

type GuardPayload = {
  tool: "shell" | "edit"
  command?: string
  paths?: readonly string[]
  cwd: string
}

// Fail closed only on an explicit deny. A missing or crashing guard must not lock the session.
function denyMessage(guard: string, payload: GuardPayload): Promise<string | null> {
  return new Promise((resolve) => {
    let settled = false
    const finish = (value: string | null) => {
      if (settled) return
      settled = true
      resolve(value)
    }
    const child = spawn("bash", [guard], { stdio: ["pipe", "pipe", "pipe"] })
    let out = ""
    const timer = setTimeout(() => {
      child.kill("SIGKILL")
      finish("Blocked: repository guard timed out.")
    }, GUARD_TIMEOUT_MS)
    child.stdout.setEncoding("utf8")
    child.stdout.on("data", (chunk: string) => {
      out += chunk
    })
    child.on("error", () => {
      clearTimeout(timer)
      finish(null)
    })
    child.on("close", () => {
      clearTimeout(timer)
      const text = out.trim()
      if (!text) {
        finish(null)
        return
      }
      try {
        const parsed = JSON.parse(text) as { effect?: string; message?: string }
        finish(parsed.effect === "deny" ? parsed.message || "Blocked by repository guard." : null)
      } catch {
        finish(null)
      }
    })
    child.stdin.end(JSON.stringify(payload))
  })
}

export default Plugin.define({
  id: "personal-toolkit.guard",
  async setup(ctx) {
    const root = ctx.location.project?.canonical ?? ctx.location.directory
    const guard = path.join(root, ".opencode/hooks/guard.sh")

    await ctx.permission.hook("evaluate", async (event) => {
      if (event.action !== "shell" && event.action !== "edit") return
      if (event.resources.length === 0) return
      const payload: GuardPayload =
        event.action === "shell"
          ? { tool: "shell", command: event.resources.join(" && "), cwd: root }
          : { tool: "edit", paths: event.resources, cwd: root }
      const message = await denyMessage(guard, payload)
      if (!message) return
      event.effect = "deny"
      event.message = message
    })
  },
})
