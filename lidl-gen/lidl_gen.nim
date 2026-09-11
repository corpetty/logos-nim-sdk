## logos_sdk lidl-gen — the CLI. Parses a `.lidl` contract through the canonical
## LIDL C frontend (`lidl_c.h`: `lidl_parse_to_json`), then emits Nim via the pure
## `gen` core. The Nim counterpart of logos-rust-sdk's `lidl-gen` binary.
##
## Usage:
##   lidl_gen provider <contract.lidl> <out.nim>            # the module's surface
##   lidl_gen client   <contract.lidl> <out.nim> [target]   # a typed consumer client
##   lidl_gen driver   <contract.lidl> <out.nim> [coordinatable-csv] [tier1-csv]
##       # a Muster driver manifest (P-D5): effect schema + domain tag + card copy per
##       # coordinatable action, + Tier-1 skeletons. `coordinatable-csv` curates which
##       # methods are actions (omit → the read-pruning heuristic); `tier1-csv` names
##       # the module-native ones needing a hand-written driver.
##
## Build needs the LIDL C bridge headers/archives, passed via -d:
##   nim c -d:LIDL_INC=<dir> -d:LIDL_C_A=<liblidl_c.a> -d:LIDL_A=<liblidl.a> \
##         lidl-gen/lidl_gen.nim
## (mirrors module/tools/lidl_gen.nim's build in this repo.)

import std/[json, os, strutils]
import "./gen"

proc csv(s: string): seq[string] =
  ## Split a comma-separated CLI arg into a trimmed, non-empty list.
  for part in s.split(','):
    let t = part.strip()
    if t.len > 0: result.add t

const LIDL_INC {.strdefine.} = ""
const LIDL_C_A {.strdefine.} = ""
const LIDL_A {.strdefine.} = ""
{.passC: "-I" & LIDL_INC.}
{.passL: LIDL_C_A & " " & LIDL_A & " -lstdc++".}
proc lidl_parse_to_json(lidl: cstring, err: ptr cstring): cstring {.importc, cdecl.}
proc lidl_free_string(s: cstring) {.importc, cdecl.}

proc parseLidl(src: string): JsonNode =
  var err: cstring = nil
  let js = lidl_parse_to_json(src.cstring, addr err)
  if js == nil:
    let msg = (if err != nil: $err else: "unknown error")
    if err != nil: lidl_free_string(err)
    raise newException(ValueError, "lidl parse failed: " & msg)
  result = parseJson($js)
  lidl_free_string(js)

when isMainModule:
  if paramCount() < 3:
    quit("usage: lidl_gen <provider|client> <contract.lidl> <out.nim> [target]", 1)
  let mode = paramStr(1)
  let contract = parseLidl(readFile(paramStr(2)))
  let outFile = paramStr(3)
  case mode
  of "provider":
    writeFile(outFile, genProvider(contract))
  of "client":
    let target = (if paramCount() >= 4: paramStr(4) else: "")
    writeFile(outFile, genClient(contract, target))
  of "driver":
    let coordinatable = (if paramCount() >= 4: csv(paramStr(4)) else: @[])
    let tier1 = (if paramCount() >= 5: csv(paramStr(5)) else: @[])
    writeFile(outFile, genDriver(contract, coordinatable, tier1))
  else:
    quit("unknown mode: " & mode & " (want provider|client|driver)", 1)
  echo "generated ", outFile, " (", mode, ") from ", paramStr(2),
       " — ", contract{"methods"}.len, " methods"
