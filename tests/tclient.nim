## The generated consumer client compiles against the runtime (compile only, as
## tffi: lp_* resolves at plugin link time). Generates a client for a contract that
## spans the type kinds, writes it, and `nim c --noLinking:on`s it — so a generator
## change that emits invalid Nim (a bad async twin, say) fails here, not in a consumer.
import std/[json, os, osproc, strutils]
import "../lidl-gen/gen"

let contract = %*{
  "name": "counter_module",
  "methods": [
    {"name": "increment", "params": [{"name": "amount", "type": {"name": "uint"}}],
     "returnType": {"name": "int"}},
    {"name": "echo", "params": [{"name": "msg", "type": {"name": "tstr"}}],
     "returnType": {"name": "tstr"}},
    {"name": "store", "params": [{"name": "blob", "type": {"name": "bstr"}}],
     "returnType": {"name": "bool"}},
    {"name": "health", "params": [], "returnType": {"name": "tstr"}},
    {"name": "snapshot", "params": [], "returnType": {"name": "map"}}
  ]
}

let dir = getTempDir() / "logos_sdk_tclient"
createDir(dir)
let client = dir / "counter_client.nim"
writeFile(client, genClient(contract))
# A use of every twin, so each is instantiated and type-checked, not just parsed.
writeFile(dir / "use_client.nim", """
import std/json
import ./counter_client
proc use() =
  let c = newCounterClient("my_module")
  discard c.increment(1)
  discard c.echoOrRaise("x")
  discard c.incrementAsync(1, proc (r: int) = discard r)
  discard c.echoAsync("x", proc (r: string) = discard r)
  discard c.storeAsync(@[byte 1], proc (r: bool) = discard r)
  discard c.healthAsync(proc (r: string) = discard r)
  discard c.snapshotAsync(proc (r: JsonNode) = discard r)
when isMainModule:
  if false: use()
""")
let src = currentSourcePath().parentDir.parentDir / "src"
let (output, rc) = execCmdEx("nim c --noLinking:on --hints:off --path:" & quoteShell(src) &
                             " -o:/dev/null " & quoteShell(dir / "use_client.nim"))
if rc != 0:
  echo output
  quit "FAIL: the generated client does not compile", 1
echo "PASS: the generated client (plain, raising and async twins) compiles"
