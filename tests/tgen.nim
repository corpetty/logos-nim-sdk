## Headless tests for the pure LIDL→Nim generator (no lidl_c.h, runs under `nim r`).
## Feeds a hand-built parsed-contract JsonNode — the shape lidl_parse_to_json
## returns — and asserts the generated provider surface and consumer client.

import std/[unittest, json, strutils]
import "../lidl-gen/gen"

# A stand-in for a parsed .lidl contract: three methods spanning the type kinds.
let contract = %*{
  "name": "counter_module",
  "methods": [
    {"name": "increment",
     "params": [{"name": "amount", "type": {"name": "uint"}}],
     "returnType": {"name": "int"}},
    {"name": "echo",
     "params": [{"name": "msg", "type": {"name": "tstr"}}],
     "returnType": {"name": "tstr"}},
    {"name": "store",
     "params": [{"name": "blob", "type": {"name": "bstr"}}],
     "returnType": {"name": "bool"}}
  ]
}

suite "lidl-gen: provider surface":
  let p = genProvider(contract)

  test "imports the SDK runtime (api seam)":
    check "import logos_sdk/api" in p

  test "emits all seven logos_module_* exports":
    for e in ["logos_module_dispatch", "logos_module_set_context",
              "logos_module_set_emit_callback", "logos_module_accept_token",
              "logos_module_get_protocol_version", "logos_module_get_methods",
              "logos_module_string_free"]:
      check (e & "(") in p or (e & "():") in p

  test "accept_token delegates to saveToken (the regression guard)":
    check "saveToken(" in p

  test "dispatch has a case arm per method + arg-count guard":
    check "of \"increment\":" in p
    check "of \"echo\":" in p
    check "of \"store\":" in p
    check "args.len < 1" in p

  test "author forward-decls are module-prefixed (namespaced off system idents)":
    check "proc counterIncrement(amount: int): int" in p
    check "proc counterEcho(msg: string): string" in p   # bstr/tstr → string at author seam
    check "proc counterStore(blob: string): bool" in p

  test "context/emit delegate to the SDK":
    check "setContext(" in p
    check "setEmitCallback(" in p

suite "lidl-gen: consumer client":
  let c = genClient(contract)

  test "client type + constructor target the module":
    check "type CounterClient* = ref object" in c
    check "newPluginProxy(\"counter_module\"" in c

  test "typed method signatures map LIDL → Nim":
    check "proc increment*(c: CounterClient, amount: int): int =" in c
    check "proc echo*(c: CounterClient, msg: string): string =" in c
    check "proc store*(c: CounterClient, blob: seq[byte]): bool =" in c

  test "bstr arg is encoded via bytesArg":
    check "bytesArg(blob)" in c

  test "scalar args are JSON-encoded":
    check "args(%amount)" in c

  test "return decode matches the return type":
    check "r.value.getInt()" in c        # increment -> int
    check "r.value.getStr()" in c        # echo -> string
    check "r.value.getBool()" in c       # store -> bool

  test "each method also gets a raising twin":
    check "proc incrementOrRaise*(c: CounterClient, amount: int): int =" in c
    check "proc echoOrRaise*(c: CounterClient, msg: string): string =" in c
    check "proc storeOrRaise*(c: CounterClient, blob: seq[byte]): bool =" in c

  test "the raising twin raises on !ok and on decode mismatch":
    check "if not r.ok: raise newLogosCallError(\"increment\", r.error)" in c
    check "raise newLogosCallError(\"increment\", %\"result did not decode to int\")" in c

  test "bstr return would decode via b64urlDecode":
    let c2 = genClient(%*{"name": "blob_module",
      "methods": [{"name": "fetch", "params": [], "returnType": {"name": "bstr"}}]})
    check "b64urlDecode(" in c2
    check "type BlobClient*" in c2

suite "lidl-gen: naming":
  test "clientTypeName strips _module and camel-cases":
    check clientTypeName("counter_module") == "CounterClient"
    check clientTypeName("delivery_module") == "DeliveryClient"
    check clientTypeName("multi_word_module") == "MultiWordClient"

# A contract mixing reads (pruned), an action with a @brief, and a module-native
# (Tier-1) action — the shape the driver manifest derives from.
let voteContract = %*{
  "name": "vote_module",
  "methods": [
    {"name": "version", "params": [], "returnType": {"name": "tstr"}},
    {"name": "getTally", "params": [], "returnType": {"name": "int"}},
    {"name": "cast",
     "params": [{"name": "proposalId", "type": {"name": "tstr"}},
                {"name": "choice", "type": {"name": "uint"}}],
     "returnType": {"name": "bool"},
     "description": "Cast your vote on a proposal."},
    {"name": "settle",
     "params": [{"name": "proposalId", "type": {"name": "tstr"}}],
     "returnType": {"name": "bool"},
     "description": "Finalize a proposal on-chain (module-native signing)."}
  ]
}

suite "lidl-gen: driver — selection":
  test "isReadName prunes queries, keeps actions":
    check isReadName("version")
    check isReadName("getTally")
    check isReadName("listItems")
    check not isReadName("cast")
    check not isReadName("settle")

  test "invokeDomain is byte-exact with muster's tag (invariant 5)":
    check invokeDomain("vote_module", "cast") == "muster.invoke.vote_module.cast.v1"

  test "no curation → heuristic keeps only the non-reads":
    let chosen = coordinatableMethods(voteContract, @[])
    var names: seq[string]
    for m in chosen: names.add m["name"].getStr()
    check names == @["cast", "settle"]

  test "explicit curation is the EXACT set (never a silent guess)":
    let chosen = coordinatableMethods(voteContract, @["cast"])
    check chosen.len == 1
    check chosen[0]["name"].getStr() == "cast"

suite "lidl-gen: driver — manifest":
  let d = genDriver(voteContract, @["cast", "settle"], @["settle"])

  test "generated, non-editable, names the module const":
    check "GENERATED driver manifest for vote_module" in d
    check "const VoteActionsJson* = " in d
    check "let VoteActions* = parseJson(VoteActionsJson)" in d

  test "each action carries its dCBOR domain tag":
    check "muster.invoke.vote_module.cast.v1" in d
    check "muster.invoke.vote_module.settle.v1" in d

  test "the effect schema names the typed args (for canonicalize + card)":
    check "\"proposalId\"" in d
    check "\"choice\"" in d

  test "the card label comes from the LIDL description (@brief)":
    check "Cast your vote on a proposal." in d

  test "tier + curated flags are explicit":
    check "\"tier\": 0" in d      # cast — generic invoke
    check "\"tier\": 1" in d      # settle — module-native
    check "\"curated\": true" in d

  test "a Tier-1 action emits a driver skeleton to complete":
    check "TIER-1 DRIVER SKELETON — vote_module.settle" in d
    check "type voteSettleDriver* = ref object of Driver" in d
    check "method canonicalize*(d: voteSettleDriver" in d
    check "method verifyContribution*(d: voteSettleDriver" in d
    check "implement against the module's" in d

  test "a Tier-0 action emits NO skeleton (config only)":
    check "TIER-1 DRIVER SKELETON — vote_module.cast" notin d

  test "the manifest is a compilable const (block-comment skeletons don't break it)":
    # the skeleton is a Nim block comment #[ ... ]# so the file still parses
    check "#[" in d and "]#" in d

suite "lidl-gen: driver — card fallback":
  test "no @brief → label falls back to module.method (no fabricated copy)":
    let noBrief = %*{"name": "bank_module",
      "methods": [{"name": "transfer",
        "params": [{"name": "to", "type": {"name": "tstr"}}],
        "returnType": {"name": "bool"}}]}
    let d = genDriver(noBrief, @["transfer"])
    check "\"label\": \"bank_module.transfer\"" in d
    check "\"brief\": \"\"" in d
