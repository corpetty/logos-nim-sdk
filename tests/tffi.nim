## ffi.nim compiles for a consumer under gcc >= 14 (compile only: `nim c --noLinking:on`,
## since lp_* resolves only at plugin link time). A handle held in a variable and passed
## to an lp_* prototype must be the SAME C type as the prototype's parameter; with the
## handles as `importc: "struct LpClient"` and no file-scope declaration, each prototype
## declared its own struct and gcc 14 rejected the call as an incompatible pointer. Also
## pins the consumer-side token calls a host needs to register a view's token.
import logos_sdk/ffi

proc useHandles() =
  var client: ptr LpClient = nil
  var outResult, outError: cstring
  discard lp_invoke(client, "health", "[]", 0, addr outResult, addr outError)
  discard lp_inform_module_token(client, "auth", "muster_ui", "token")
  let t = lp_token_get("capability_module")
  if t != nil: lp_string_free(t)
  var sub: ptr LpSubscription = lp_subscribe(client, "event", nil, nil)
  lp_unsubscribe(sub)
  lp_client_destroy(client)

when isMainModule:
  if false: useHandles()
