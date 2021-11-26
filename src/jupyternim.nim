import std/[dynlib, json, options, os, osproc, sequtils, strformat, strutils, tables]
import ./jupyternimpkg/[messages, nimConfigs, sockets, utils]
import docopt
from zmq import zmqdll # to check against the name nim-zmq uses

when (NimMajor, NimMinor, NimPatch) > (1, 3, 5): # Changes in devel
  import std/exitprocs

## A Jupyter Kernel for Nim.
##
## Can be built with -d:useHcr for **very** experimental hot code reloading support.
##
## Install with:
##
## .. code-block::
##   nimble install jupyternim -y
##
## Run ``jupyternim -v`` to display version and some info about compilation flags, eg. hcr and debug.
##
## See also the [display](./display.html) package.

const doc = fmt"""
Jupyter Nim Kernel.

Usage:
  jupyternim install [--nim=<path>] [--cfg=<path>] [--nimbleDir=<path>]
  jupyternim run <connection-file> [--nim=<path>] [--cfg=<path>] [--nimbleDir=<path>]
  jupyternim (-h | --help)
  jupyternim (-v | --version)

Options:
  -h --help           Show this screen.
  -v --version        Show version.
  --nim=<path>        Path to Nim compiler.
  --cfg=<path>        Path to Nim configuration file.
  --nimbleDir=<path>  Path to the nimble directory.
"""

type Kernel = object
  ## The kernel object. Contains the sockets.
  hb: Heartbeat # The heartbeat socket object
  shell: Shell
  control: Control
  pub: IOPub
  sin: StdIn
  running: bool
  nimConfig: NimConfig


proc installKernelSpec(nimConfig: NimConfig) =
  ## Install the kernel, executed when running jupyternim directly
  # no connection file passed: assume we're registering the kernel with jupyter
  echo "[Jupyternim] Installing Jupyter Nim Kernel"
  var args = newSeq[string]()
  if nimConfig.bin.isSome:
    args.add("--nim:" & nimConfig.nim)
  if nimConfig.nimbleDir.isSome:
    args.add("--nimbleDir:" & nimConfig.nimbleDir.get)
  args.insert(["path", "jupyternim"], args.len)

  # TODO: assume this can fail, check exitcode
  var pkgDir = execProcess("nimble", args=args, options={poStdErrToStdOut, poUsePath}).strip().splitLines()[^1]
  var (h, t) = pkgDir.splitPath()

  var pathToJN = (if t == "src": h else: pkgDir) /
      "jupyternim" # move jupyternim to a const string in common.nim
  pathToJN = pathToJN.changeFileExt(ExeExt)

  var argv = @[pathToJN, "run"]
  if nimConfig.bin.isSome:
    argv.insert(@["--nim=", nimConfig.bin.get], argv.len)
  if nimConfig.cfg.isSome:
    argv.insert(@["--cfg=", nimConfig.cfg.get], argv.len)
  if nimConfig.nimbleDir.isSome:
    argv.insert(@["--nimbleDir=", nimConfig.nimbleDir.get], argv.len)
  argv.add("{connection_file}")

  let kernelspec = %*{
    "argv": argv,
    "display_name": "Nim " & nimConfig.nimVersion,
    "language": "nim",
    "file_extension": ".nim"}

  writeFile(pkgDir / "jupyternimspec"/"kernel.json", $kernelspec)

  # Copying the kernelspec to expected location
  #  ~/.local/share/jupyter/kernels (Linux)
  #  ~/Library/Jupyter/kernels (Mac)
  #  getEnv("APPDATA") & "jupyter" / "kernels" (Windows)
  # should be equivalent to `jupyter-kernelspec install pkgDir/jupyternimspec --user`
  let kernelspecdir = when defined windows: getEnv("APPDATA") / "jupyter" /
      "kernels" / "jupyternimspec"
                      elif defined(macosx) or defined(macos): expandTilde(
                          "~/Library/Jupyter/kernels") / "jupyternimspec"
                      elif defined linux: expandTilde(
                          "~/.local/share/jupyter/kernels") / "jupyternimspec"
  echo "[Jupyternim] Copying Jupyternim kernelspec to ", kernelspecdir
  copyDir(pkgDir / "jupyternimspec", kernelspecdir)

  echo "[Jupyternim] Nim kernel registered, you can now try it in favourite jupyter-compatible environment"

  var zmql = loadLibPattern(zmqdll)
  echo "[Jupyternim] Found zmq library: ", not zmql.isNil()
  if zmql.isNil():
    echo "[Jupyternim] WARNING: No zmq library could be found, please install it"
  else: zmql.unloadLib()

  when defined useHcr:
    echo "[Jupyternim] Note: jupyternim has hotcodereloading:on, it is **very** unstable"
    echo "[Jupyternim] Please report any issues to https://github.com/stisa/jupyternim"

  quit(0)

proc initKernel(connfile: string, nimConfig: NimConfig): Kernel =
  when defined useHcr:
    echo "[Jupyternim] You're running jupyternim with hotcodereloading:on, it is **very** unstable"
    echo "[Jupyternim] Please report any issues to https://github.com/stisa/jupyternim"
  debug "Initing from: ", connfile, " exists: ", connfile.fileExists
  if not connfile.fileExists:
    debug "Connection file doesn't exit at ", connfile
    quit(1)

  let connmsg = connfile.parseConnMsg()
  if not dirExists(jnTempDir):
    # Ensure temp folder exists
    createDir(jnTempDir)

  result.nimConfig = nimConfig
  result.hb = createHB(connmsg.ip, connmsg.hb_port) # Initialize the heartbeat socket
  result.pub = createIOPub(connmsg.ip, connmsg.iopub_port) # Initialize iopub
  result.shell = createShell(nimConfig, connmsg.ip, connmsg.shell_port,
      result.pub) # Initialize shell
  result.control = createControl(connmsg.ip, connmsg.control_port) # Initialize control
  result.sin = createStdIn(connmsg.ip, connmsg.stdin_port) # Initialize stdin

  result.running = true

proc loop(kernel: var Kernel) =
  #spawn kernel.hb.beat()
  debug "Entering main loop, filename: ", JNfile
  while kernel.running:
    # this is gonna crash due to timeouts... or make the pc explode with messages

    if kernel.shell.hasMsgs:
      debug "shell..."
      kernel.shell.receive()

    if kernel.control.hasMsgs:
      debug "control..."
      kernel.control.receive()

    if kernel.pub.hasMsgs:
      debug "pub..."
      kernel.pub.receive()

    if kernel.sin.hasMsgs:
      debug "stdin..."
      kernel.sin.receive()

    if kernel.hb.hasMsgs:
      debug "ping..."
      kernel.hb.pong()

    #debug "Looped once"
    sleep(300) # wait a bit before trying again TODO: needed?

proc shutdown(k: var Kernel) {.noconv.} =
  debug "Shutting Down..."
  k.running = false
  k.hb.close()
  k.pub.close()
  k.shell.close()
  k.control.close()
  k.sin.close()
  if dirExists(jnTempDir):
    # only remove our files on exit
    for f in walkDir(jnTempDir):
      if f.kind == pcFile and f.path.contains(JNfile): # our files should match this
        try:
          removeFile(f.path) # Remove temp dir on exit
        except:
          echo "[Jupyternim] failed to delete ", f.path
    debug "Cleaned up files from /.jupyternim"

proc runKernel(connfile: string, nimConfig: NimConfig) =
  # Main loop: this is executed when jupyter starts the kernel

  var kernel: Kernel = initKernel(connfile, nimConfig)

  when (NimMajor, NimMinor, NimPatch) > (1, 3, 5):
    addExitProc(proc() = kernel.shutdown())

  setControlCHook(proc(){.noconv.} = quit())

  kernel.loop()

let arguments = commandLineParams() # [0] is ususally the connection file
if arguments.len > 1 and arguments[0][^2..^1] == "py":
  # vscode-python shenanigans
  quit(1)

let args = docopt(doc, version = "Jupyter Nim " & JNKernelVersion)
let nimConfig = createNimConfigFromArgs(args)

if args["install"]:
  installKernelSpec(nimConfig)
elif args["run"]:
  if args["<connection-file>"].kind == vkStr:
    let connectionFile = $(args["<connection-file>"])
    echo "connectionFile=" & connectionFile
    echo "connectionFile[^4..^1]=" & $connectionFile[^4..^1]
    if connectionFile[^4..^1] == "json":
      runKernel(connectionFile, nimConfig)
    else:
      echo "Error: unrecognized single argument: ", connectionFile
      quit(1)
  else:
    echo "Error: connection file path required"
    quit(1)
else:
  echo "Unknown command"
  echo(doc.strip())
  quit(1)

quit(0)
