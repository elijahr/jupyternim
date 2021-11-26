
import std/[options, osproc, strutils, tables]
import docopt, regex

type NimConfig* = object
  bin*: Option[string]  # Path to Nim compiler.
  cfg*: Option[string]  # Path to Nim configuration file.
  nimbleDir*: Option[string] # Path to the Nimble directory.

type UnknownNimVersionDefect* = object of Defect

proc createNimConfig*(bin, cfg, nimbleDir: Option[string]): NimConfig =
  result.bin = bin
  result.cfg = cfg
  result.nimbleDir = nimbleDir

proc createNimConfigFromArgs*(args: Table[string, Value]): NimConfig =
  let bin = case args["--nim"].kind
    of vkStr: some($args["--nim"])
    else: none(string)

  let cfg = case args["--cfg"].kind
    of vkStr: some($args["--cfg"])
    else: none(string)

  let nimbleDir = case args["--nimbleDir"].kind
    of vkStr: some($args["--nimbleDir"])
    else: none(string)

  result = createNimConfig(bin, cfg, nimbleDir)

proc nim*(nimConfig: NimConfig): string =
  result = if nimConfig.bin.isSome: nimConfig.bin.get
    else: "nim"

proc nimVersion*(nimConfig: NimConfig): string {.raises: [Exception, UnknownNimVersionDefect].} =
  let text = execProcess(nimConfig.nim & " -v").splitLines[0]
  var m: RegexMatch
  if match(text, re".+ Version ([^\s]+).*", m):
    result = m.group(0, text)[0]
  else:
    raise newException(UnknownNimVersionDefect, "Could not parse Nim version from " & nimConfig.nim & " output: " & text)
