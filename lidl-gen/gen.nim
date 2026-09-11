## Pure LIDL → Nim code generation. Operates on the parsed-contract `JsonNode`
## (the shape `lidl_parse_to_json` returns), so every proc here is headless and
## unit-testable — no `lidl_c.h`, no FFI. The CLI (`lidl_gen.nim`) adds only the
## C parse bridge and file I/O on top.
##
## Two outputs, mirroring logos-rust-sdk's two generators:
##   • genProvider — the module's own surface: the seven `logos_module_*` C
##     exports + the dispatch table + the method descriptor, delegating context /
##     emit / token / protocol to the `logos_sdk` runtime. The author writes one
##     `proc <method>(...)` per contract method; the dispatch forwards to it.
##   • genClient — a typed consumer client per dependency: a `PluginProxy` wrapper
##     exposing each contract method as a Nim proc that encodes args, calls, and
##     decodes the result.
##   • genDriver — a Muster *driver manifest*: per coordinatable method, the effect
##     schema, its dCBOR domain tag (invariant 5), and the card copy (label + fields
##     from the LIDL `description`), plus a Tier-1 driver skeleton for module-native
##     actions. This is the "module → driver" derivation (muster epic exo-fa4, P-D5):
##     a Logos module method becomes a coordinated Muster intent. Mechanical parts
##     only — curation (which methods are actions) and the authorization/finality
##     model are declared, never guessed.

import std/[json, strutils]

# ── contract accessors ───────────────────────────────────────────────────────

proc primName(t: JsonNode): string = t{"name"}.getStr("any")

proc methods(contract: JsonNode): JsonNode =
  result = contract{"methods"}
  if result.isNil: result = newJArray()

proc contractName*(contract: JsonNode): string =
  ## The module name a client targets. LIDL puts it at the top level; fall back to
  ## a neutral default so generation never fails on a nameless contract.
  contract{"name"}.getStr("module")

# ── PROVIDER side (matches the proven muster codegen's type decisions) ─────────

proc argGetter(t: JsonNode, idx: int): string =
  case primName(t)
  of "tstr", "bstr": "args[" & $idx & "].getStr()"
  of "int", "uint": "args[" & $idx & "].getInt()"
  of "bool": "args[" & $idx & "].getBool()"
  else: "args[" & $idx & "]"

proc providerProcRetNim(t: JsonNode): string =
  case primName(t)
  of "int", "uint": "int"
  of "bool": "bool"
  else: "string"          # tstr/bstr and anything else cross the author seam as string

proc qtType(t: JsonNode): string =
  case primName(t)
  of "tstr": "QString"
  of "bstr": "QByteArray"
  of "int": "int"
  of "uint": "uint"
  of "bool": "bool"
  else: "QVariant"

proc moduleStem*(name: string): string =
  ## "counter_module" → "counter"; "multi_word_module" → "multiWord";
  ## "muster_module" → "muster". The camelCase stem (lowercase first) that
  ## namespaces author procs and names the client type.
  var base = name
  if base.endsWith("_module"): base = base[0 ..< base.len - "_module".len]
  var up = false
  for i, ch in base:
    if ch == '_': up = true
    elif up: result.add ch.toUpperAscii(); up = false
    elif i == 0: result.add ch.toLowerAscii()
    else: result.add ch
  if result.len == 0: result = "impl"

proc authorProcName*(stem, name: string): string =
  ## The author-side proc a dispatch arm forwards to: `<stem><Method>`, e.g.
  ## "muster" + "health" → "musterHealth". Prefixing namespaces the author's impl
  ## away from system/imported identifiers — without it a method literally named
  ## `echo` or `add` collides. This reproduces muster's hand convention exactly.
  stem & name[0].toUpperAscii() & name[1..^1]

proc providerParamNim(t: JsonNode): string =
  ## Author-seam Nim type for a param — must agree with `argGetter` (a bool param
  ## reaches the author as `getBool()`, so it is declared `bool`, not `string`).
  case primName(t)
  of "int", "uint": "int"
  of "bool": "bool"
  else: "string"          # tstr/bstr arrive as their getStr() string

proc genForwardDecls(ms: JsonNode, stem: string): string =
  for m in ms:
    let name = m["name"].getStr()
    let params = m{"params"}
    var sig: seq[string]
    if not params.isNil:
      for p in params:
        sig.add p["name"].getStr() & ": " & providerParamNim(p["type"])
    result.add "proc " & authorProcName(stem, name) & "(" & sig.join(", ") & "): " &
      providerProcRetNim(m["returnType"]) & "\n"

proc genDispatch(ms: JsonNode, stem: string): string =
  result = "proc dispatch(meth: string, args: JsonNode): JsonNode =\n  case meth\n"
  for m in ms:
    let name = m["name"].getStr()
    let params = m{"params"}
    let np = (if params.isNil: 0 else: params.len)
    var parts: seq[string]
    if not params.isNil:
      for i in 0 ..< params.len:
        parts.add argGetter(params[i]["type"], i)
    result.add "  of \"" & name & "\":\n"
    if np > 0:
      result.add "    if args.kind != JArray or args.len < " & $np &
                 ": return newJNull()\n"
    result.add "    %" & authorProcName(stem, name) & "(" & parts.join(", ") & ")\n"
  result.add "  else:\n    nil\n"

proc genGetMethods(ms: JsonNode): string =
  var entries: seq[string]
  for m in ms:
    let name = m["name"].getStr()
    let params = m{"params"}
    var pjson, sigTypes: seq[string]
    if not params.isNil:
      for p in params:
        pjson.add "{\"name\":\"" & p["name"].getStr() & "\",\"type\":\"" &
          qtType(p["type"]) & "\"}"
        sigTypes.add qtType(p["type"])
    entries.add "{\"isInvokable\":true,\"name\":\"" & name & "\"," &
      "\"parameters\":[" & pjson.join(",") & "]," &
      "\"returnType\":\"" & qtType(m["returnType"]) & "\"," &
      "\"signature\":\"" & name & "(" & sigTypes.join(",") & ")\"}"
  "[" & entries.join(",") & "]"

const providerExports = """
proc logos_module_dispatch(meth: cstring, argsJson: cstring): cstring {.exportc, cdecl.} =
  if meth == nil: return nil
  var args = newJArray()
  if argsJson != nil:
    try:
      let parsed = parseJson($argsJson)
      if parsed.kind == JArray: args = parsed
      else: return nil
    except CatchableError: return nil
  let res = dispatch($meth, args)
  if res == nil or res.isNil: return nil
  allocCString($res)

proc logos_module_set_context(modulePath: cstring, instanceId: cstring,
                              instancePersistencePath: cstring) {.exportc, cdecl.} =
  proc s(p: cstring): string = (if p == nil: "" else: $p)
  setContext(s(modulePath), s(instanceId), s(instancePersistencePath))

proc logos_module_set_emit_callback(cb: EmitCb, userData: pointer) {.exportc, cdecl.} =
  setEmitCallback(cb, userData)

# Save the token in THIS plugin's protocol stack, or every outbound lp_invoke is
# rejected and the target's node never boots. Delegates to the SDK's saveToken so
# a regen can never drop it (the lesson of muster's cross-host regression).
proc logos_module_accept_token(moduleName: cstring, token: cstring): cint {.exportc, cdecl.} =
  if moduleName == nil or token == nil: return -1
  discard saveToken($moduleName, $token)
  0

proc logos_module_get_protocol_version(): cstring {.exportc, cdecl.} =
  cstring"0.1.0"

proc logos_module_string_free(s: cstring) {.exportc, cdecl.} =
  freeCString(s)

{.emit: "extern void NimMain(void); static void __attribute__((constructor)) logos_module_ctor(void) { NimMain(); }".}
"""

proc genProvider*(contract: JsonNode): string =
  ## The module's provider surface. Delegates context/emit/token/cstring to the
  ## `logos_sdk` runtime; the author supplies one proc per contract method.
  let ms = methods(contract)
  let stem = moduleStem(contractName(contract))
  result = "## GENERATED from " & contractName(contract) &
           " by logos_sdk lidl-gen — do not edit.\n" &
           "## The author supplies one `proc " & stem & "<Method>*(...)` per method.\n" &
           "import std/json\nimport logos_sdk/api\n\n"
  result.add genForwardDecls(ms, stem) & "\n"
  result.add genDispatch(ms, stem) & "\n"
  result.add "proc logos_module_get_methods(): cstring {.exportc, cdecl.} =\n"
  result.add "  allocCString($parseJson(\"\"\"" & genGetMethods(ms) & "\"\"\"))\n\n"
  result.add providerExports

# ── CONSUMER side: a typed client per dependency ──────────────────────────────

proc clientTypeName*(target: string): string =
  ## "counter_module" → "CounterClient"; "delivery_module" → "DeliveryClient".
  let stem = moduleStem(target)
  stem[0].toUpperAscii() & stem[1..^1] & "Client"

proc clientParamType(t: JsonNode): string =
  case primName(t)
  of "tstr": "string"
  of "bstr": "seq[byte]"
  of "int", "uint": "int"
  of "bool": "bool"
  else: "JsonNode"

proc clientArgEncode(pname: string, t: JsonNode): string =
  case primName(t)
  of "bstr": "bytesArg(" & pname & ")"
  else: "%" & pname            # string/int/bool → JSON scalar; JsonNode passes through as %

proc clientRetDecode(t: JsonNode): string =
  ## LENIENT decode of `r.value` into the Nim return type — a typed zero-value on
  ## any failure, so the plain `<method>` never raises. The `<method>OrRaise` twin
  ## surfaces the error instead (see clientRetDecodeStrict).
  case primName(t)
  of "tstr":
    "(if r.ok and r.value != nil and r.value.kind == JString: r.value.getStr() else: \"\")"
  of "int", "uint":
    "(if r.ok and r.value != nil and r.value.kind == JInt: r.value.getInt() else: 0)"
  of "bool":
    "(if r.ok and r.value != nil and r.value.kind == JBool: r.value.getBool() else: false)"
  of "bstr":
    "(if r.ok and r.value != nil and r.value.kind == JObject and r.value.hasKey(\"_bytes\"): " &
      "b64urlDecode(r.value[\"_bytes\"].getStr()) else: newSeq[byte]())"
  else:
    "(if r.ok and r.value != nil: r.value else: newJNull())"

proc clientRetDecodeStrict(t: JsonNode, meth: string): string =
  ## STRICT decode for the raising twin: assumes `r.ok` already checked. Raises a
  ## LogosCallError when the result doesn't match the contract's declared type,
  ## rather than fabricating a zero-value.
  let bad = "raise newLogosCallError(\"" & meth & "\", %\"result did not decode to " &
            primName(t) & "\")"
  case primName(t)
  of "tstr":
    "(if r.value != nil and r.value.kind == JString: r.value.getStr() else: " & bad & ")"
  of "int", "uint":
    "(if r.value != nil and r.value.kind == JInt: r.value.getInt() else: " & bad & ")"
  of "bool":
    "(if r.value != nil and r.value.kind == JBool: r.value.getBool() else: " & bad & ")"
  of "bstr":
    "(if r.value != nil and r.value.kind == JObject and r.value.hasKey(\"_bytes\"): " &
      "b64urlDecode(r.value[\"_bytes\"].getStr()) else: " & bad & ")"
  else:
    "(if r.value != nil: r.value else: newJNull())"

proc genClient*(contract: JsonNode, target = ""): string =
  ## A typed consumer client for the module described by `contract`. `target` is
  ## the module name to call (defaults to the contract's own name).
  let tgt = (if target.len > 0: target else: contractName(contract))
  let cn = clientTypeName(tgt)
  let ms = methods(contract)
  result = "## GENERATED consumer client for " & tgt &
           " by logos_sdk lidl-gen — do not edit.\n" &
           "import std/json\nimport logos_sdk\n\n"
  result.add "type " & cn & "* = ref object\n  proxy*: PluginProxy\n\n"
  result.add "proc new" & cn & "*(origin = \"core\"): " & cn & " =\n" &
             "  " & cn & "(proxy: newPluginProxy(\"" & tgt & "\", origin))\n\n"
  for m in ms:
    let name = m["name"].getStr()
    let params = m{"params"}
    var sig, enc: seq[string]
    if not params.isNil:
      for p in params:
        let pn = p["name"].getStr()
        sig.add pn & ": " & clientParamType(p["type"])
        enc.add clientArgEncode(pn, p["type"])
    let sigStr = (if sig.len > 0: ", " & sig.join(", ") else: "")
    let retT = clientParamType(m["returnType"])
    let callLine = "  let r = c.proxy.callSync(\"" & name & "\", args(" & enc.join(", ") & "))\n"
    # lenient: typed zero-value on failure, never raises
    result.add "proc " & name & "*(c: " & cn & sigStr & "): " & retT & " =\n"
    result.add callLine
    result.add "  " & clientRetDecode(m["returnType"]) & "\n\n"
    # raising twin: surfaces transport/method errors and decode mismatches
    result.add "proc " & name & "OrRaise*(c: " & cn & sigStr & "): " & retT & " =\n"
    result.add callLine
    result.add "  if not r.ok: raise newLogosCallError(\"" & name & "\", r.error)\n"
    result.add "  " & clientRetDecodeStrict(m["returnType"], name) & "\n\n"

# ── DRIVER side: a Muster driver manifest from a contract (P-D5) ───────────────
# The "module → driver" derivation. A Logos module method `verb(args) -> result`
# becomes a coordinated intent: the effect {module, method, args}, its dCBOR domain
# tag (invariant 5), and the intent-propose card. Only the mechanical parts are
# derived here; the design's three non-mechanical gaps (which methods are actions,
# the authorization model, what "done" means) are DECLARED by the caller, never
# guessed — see docs/design/driver-derivation.md in muster.

const readPrefixes = ["get", "is", "has", "list", "available", "version", "metrics",
                      "collect", "read", "query", "info", "status", "count", "describe"]

proc isReadName*(name: string): bool =
  ## Mirrors muster's discovery heuristic: does this name READ rather than DO? The
  ## common query prefixes + infra verbs. Curation overrides it either way — this is
  ## only the default when no coordinatable list is supplied.
  let n = name.toLowerAscii()
  for p in readPrefixes:
    if n.startsWith(p): return true
  false

proc invokeDomain*(targetModule, targetMethod: string): string =
  ## The per-(module, method) dCBOR schema id an invoke effect carries — byte-for-byte
  ## the tag muster's invoke driver uses (`muster.invoke.<module>.<method>.v1`), so a
  ## manifest-derived effect and muster's runtime effect canonicalize identically
  ## (invariant 5: different method → different domain → different signed bytes).
  "muster.invoke." & targetModule & "." & targetMethod & ".v1"

proc argSchema(params: JsonNode): JsonNode =
  ## The effect's typed arg schema — each param's name + primitive type — for both
  ## canonicalize (the fields that reach the signed bytes) and the card's fields.
  result = newJArray()
  if params.isNil: return
  for p in params:
    result.add %*{"name": p["name"].getStr(), "type": primName(p["type"])}

proc cardDescriptor(m: JsonNode, module, name: string): JsonNode =
  ## The intent-propose card copy, from LIDL: the method `description` (the @brief)
  ## becomes the action label, each param names a field. LIDL params carry no
  ## per-param description, so the field label is the param name (honest — not a
  ## fabricated sentence). Falls back to "module.method" when the brief is absent.
  let brief = m{"description"}.getStr("")
  var fields = newJArray()
  let params = m{"params"}
  if not params.isNil:
    for p in params:
      fields.add %*{"name": p["name"].getStr(), "label": p["name"].getStr(),
                    "type": primName(p["type"])}
  result = %*{
    "label": (if brief.len > 0: brief else: module & "." & name),
    "brief": brief,
    "fields": fields}

proc actionEntry(m: JsonNode, module: string, curated, tier1: bool): JsonNode =
  let name = m["name"].getStr()
  result = %*{
    "module": module,
    "method": name,
    # Tier 0 = the generic invoke driver (no code, config only). Tier 1 = a module
    # native auth/signing model (like Safe) — a hand-written driver, skeleton below.
    "tier": (if tier1: 1 else: 0),
    # How this method was selected: curated IN by the caller, or a heuristic guess
    # (a candidate a human should confirm) — never a silent "it's an action".
    "curated": curated,
    "domain": invokeDomain(module, name),
    # the effect the room proposes; muster's invoke driver canonicalizes exactly this.
    "effect": %*{"module": module, "method": name, "argSchema": argSchema(m{"params"})},
    "card": cardDescriptor(m, module, name)}

proc driverSkeleton(module, name: string): string =
  ## A Tier-1 `Driver` skeleton for a module-native action — emitted as a Nim block
  ## comment so the manifest still compiles. The mechanical shape is filled; the two
  ## procs that depend on the module's own signed form are flagged to implement, with
  ## the Safe driver named as the worked example (EIP-712 + secp owner recovery).
  let stem = moduleStem(module) & name[0].toUpperAscii() & name[1..^1]
  result = "\n#[  TIER-1 DRIVER SKELETON — " & module & "." & name & "\n" &
    "    This action carries its own authorization/signing model, so the generic\n" &
    "    dCBOR materialization is wrong: the bytes must match the MODULE's expected\n" &
    "    signed form. Implement canonicalize + verifyContribution against that format\n" &
    "    (see module/src/drivers/safe.nim — EIP-712 safeTxHash + secp owner recovery).\n" &
    "    A driver that does not pass checkConformance does not ship.\n\n" &
    "type " & stem & "Driver* = ref object of Driver\n" &
    "  # config the module's auth model needs (owners, chainId, threshold, …)\n\n" &
    "method describe*(d: " & stem & "Driver): DriverDescriptor =\n" &
    "  # rounds/threshold/membership/finality for THIS action's model.\n" &
    "  DriverDescriptor(rounds: 1, threshold: d.threshold,\n" &
    "                   serializationDomain: \"" & invokeDomain(module, name) & "\")\n\n" &
    "method canonicalize*(d: " & stem & "Driver, effect: Effect): Materialization =\n" &
    "  # TODO: encode `effect` into the module's expected signed bytes (NOT generic\n" &
    "  # dCBOR). This is the invariant-1 re-derivation target; get it byte-exact.\n" &
    "  raise newException(Defect, \"" & stem & "Driver.canonicalize: implement against the module's signed form\")\n\n" &
    "method verifyContribution*(d: " & stem & "Driver, c: Contribution, round: int): bool =\n" &
    "  # TODO: verify a contribution under the module's auth model (e.g. recover a\n" &
    "  # signer and check membership), the way safe.nim recovers an owner.\n" &
    "  raise newException(Defect, \"" & stem & "Driver.verifyContribution: implement against the module's auth model\")\n" &
    "]#\n"

proc coordinatableMethods*(contract: JsonNode, coordinatable: seq[string]): seq[JsonNode] =
  ## The methods that become actions. If `coordinatable` is non-empty it is the
  ## EXACT set (explicit curation — never a silent guess). If empty, fall back to the
  ## read-pruning heuristic and mark every entry uncurated (candidates to confirm).
  let ms = methods(contract)
  for m in ms:
    let name = m["name"].getStr()
    if coordinatable.len > 0:
      if name in coordinatable: result.add m
    elif not isReadName(name):
      result.add m

proc genDriver*(contract: JsonNode, coordinatable: seq[string] = @[],
                tier1: seq[string] = @[]): string =
  ## A Muster driver manifest for `contract`. `coordinatable` curates which methods
  ## are actions (empty → the read-pruning heuristic, entries marked uncurated).
  ## `tier1` names the module-native actions (a hand-written driver + skeleton);
  ## everything else is Tier 0 (the generic invoke driver, config only).
  let module = contractName(contract)
  let stem = moduleStem(module)
  let chosen = coordinatableMethods(contract, coordinatable)
  var entries = newJArray()
  var skels: string
  for m in chosen:
    let name = m["name"].getStr()
    let isT1 = name in tier1
    entries.add actionEntry(m, module, curated = (coordinatable.len > 0), tier1 = isT1)
    if isT1: skels.add driverSkeleton(module, name)
  let stemCap = stem[0].toUpperAscii() & stem[1..^1]
  # Emit the manifest as a compile-time JSON-string const (embeddable, diffable) plus
  # a parsed node consumers read. A JsonNode is a ref, so it can't be a `const` — the
  # string can, and `parseJson` at module scope gives the node.
  result = "## GENERATED driver manifest for " & module &
           " by logos_sdk lidl-gen — do not edit.\n" &
           "## Per coordinatable action: the effect schema, its dCBOR domain tag\n" &
           "## (invariant 5), and the intent-propose card copy. Tier-0 actions register\n" &
           "## muster's generic `invoke` driver from this config; Tier-1 actions need a\n" &
           "## hand-written driver (skeletons appended as block comments).\n" &
           "import std/json\n\n" &
           "const " & stemCap & "ActionsJson* = \"\"\"" & pretty(entries) & "\"\"\"\n" &
           "let " & stemCap & "Actions* = parseJson(" & stemCap & "ActionsJson)\n" &
           skels
