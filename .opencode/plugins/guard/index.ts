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

function denyMessage(guard: string, payload: GuardPayload): Promise<string | null> {
  const unavailable = "Blocked: repository guard could not verify this operation."
  return new Promise((resolve) => {
    let settled = false
    const finish = (value: string | null) => {
      if (settled) return
      settled = true
      resolve(value)
    }
    const child = spawn("bash", [guard, "--json-verdict"], { stdio: ["pipe", "pipe", "pipe"] })
    child.stderr.resume()
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
      finish(unavailable)
    })
    child.stdin.on("error", () => {
      clearTimeout(timer)
      finish(unavailable)
    })
    child.on("close", (code) => {
      clearTimeout(timer)
      const text = out.trim()
      if (code !== 0 || !text) {
        finish(unavailable)
        return
      }
      try {
        const parsed = JSON.parse(text)
        if (parsed?.effect === "allow") finish(null)
        else if (parsed?.effect === "deny" && typeof parsed.message === "string") {
          finish(parsed.message || unavailable)
        } else finish(unavailable)
      } catch {
        finish(unavailable)
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
      if (event.effect === "deny" || (event.action !== "shell" && event.action !== "edit")) return
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
