## The async call's callback seam, driven directly (no lp_* needed: the trampoline is
## what the ABI calls back, so a test can call it the same way). A result reaches the
## caller's closure decoded exactly as callSync decodes it, a failure arrives as a
## failed CallResult, and the box that carried the closure is released after one call.
import std/[unittest, json]
import logos_sdk/plugin

suite "callAsyncThen: the callback seam":
  test "a successful result reaches the closure, decoded as callSync decodes it":
    var got: CallResult
    var calls = 0
    let ud = boxCallDone(proc (r: CallResult) = got = r; inc calls)
    asyncResultCb(1, "\"ok\"", ud)
    check calls == 1
    check got.ok
    check got.value.kind == JString and got.value.getStr() == "ok"
    check got.raw == "\"ok\""

  test "a failure arrives as a failed CallResult carrying the error":
    var got: CallResult
    let ud = boxCallDone(proc (r: CallResult) = got = r)
    asyncResultCb(0, "{\"error\":\"no such method\"}", ud)
    check not got.ok
    check got.error["error"].getStr() == "no such method"

  test "a non-JSON result is kept as a string, never dropped":
    var got: CallResult
    let ud = boxCallDone(proc (r: CallResult) = got = r)
    asyncResultCb(1, "not json", ud)
    check got.ok and got.value.getStr() == "not json"

  test "an exception in the closure does not escape into the ABI's frame":
    let ud = boxCallDone(proc (r: CallResult) = raise newException(ValueError, "boom"))
    asyncResultCb(1, "\"ok\"", ud)   # must return normally
    check true

  test "a call the ABI never accepted still reports, once, as a failure":
    var got: CallResult
    var calls = 0
    let ud = boxCallDone(proc (r: CallResult) = got = r; inc calls)
    failCallDone(ud, "lp_client_create returned null")
    check calls == 1
    check not got.ok
