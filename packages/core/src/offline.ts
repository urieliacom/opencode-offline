import path from "path"

export namespace Offline {
  export function isEnabled() {
    const value = process.env["OPENCODE_OFFLINE_MODE"]?.toLowerCase()
    return value === "true" || value === "1"
  }

  export function deps() {
    if (!isEnabled()) return
    return process.env["OPENCODE_OFFLINE_DEPS_PATH"]
  }

  export function binary(name: string, subpath: string) {
    const root = deps()
    if (!root) return
    return path.join(root, subpath, name)
  }

  export function npm(pkg: string) {
    const root = deps()
    if (!root) return
    return path.join(root, "node_modules", pkg)
  }

  export function lsp(name: string, binary: string) {
    const root = deps()
    if (!root) return
    return path.join(root, "lsp", name, "bin", binary)
  }
}
