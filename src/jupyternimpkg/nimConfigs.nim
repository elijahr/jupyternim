
import std/[options, osproc, strutils, tables]
import docopt

type NimConfig* = object
  bin*: Option[string]  # Path to Nim compiler.
  cfg*: Option[string]  # Path to Nim configuration file.
  nimbleDir*: Option[string] # Path to the Nimble directory.

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

proc nimVersion*(nimConfig: NimConfig): string =
  result = execCmdEx(nimConfig.nim & " -v").output.splitLines[0].split("Version")[1].split(" ")[1]
