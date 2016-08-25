import zmq,json, messaging, threadpool
#import compiler/nimeval as compiler # We can actually use the nim compiler at runtime! Woho

type Heartbeat* = object
  socket*: TConnection

type IOPub* = object
  socket*: TConnection
  key*:string
  lastmsg*:WireMessage


type
  ShellObj = object
    socket*: TConnection
    key*: string # session key
    pub*: IOPub # keep a reference to pub so we can send status message
  Shell* = ref ShellObj

proc createHB*(ip:string,hbport:BiggestInt): Heartbeat =
  result.socket = zmq.listen("tcp://"&ip&":"& $hbport)

proc beat*(hb:Heartbeat) =
  while true:
    echo "[Nimkernel]: Reading hb"
    var s = hb.socket.receive() # Read from socket
    echo "[Nimkernel]: Hb read"
    if s!=nil: 
      hb.socket.send(s) # Echo back what we read
    echo "[Nimkernel]: wrote to hb"

proc createIOPub*(ip:string,port:BiggestInt , key:string): IOPub =
  result.socket = zmq.listen("tcp://"&ip&":"& $port,zmq.PUB)
  result.key = key

proc send(pub:IOPub,state:string,) =
  pub.socket.send_wire_msg_no_parent("status", %* { "execution_state": state },pub.key)

proc receive*(pub:IOPub) =
  let recvdmsg : WireMessage = pub.socket.receive_wire_msg()
  echo "[Nimkernel]: pub received:\n", $recvdmsg
  
proc createShell*(ip:string,shellport:BiggestInt,key:string,pub:IOPub): Shell =
  new result
  result.socket = zmq.listen("tcp://"&ip&":"& $shellport, zmq.ROUTER)
  result.key = key
  result.pub = pub

proc handleKernelInfo(s:Shell,m:WireMessage) =
  var content : JsonNode
  spawn s.pub.send("busy") # Tell the client we are busy
  echo "[Nimkernel]: sending: Kernelinfo sending busy"
  content = %* {
    "protocol_version": "5.0",
    "ipython_version": [1, 1, 0, ""],
    "language_version": [0, 14, 2],
    "language": "nim",
    "implementation": "nimBsd",
    "implementation_version": "0.1",
    "language_info": {
      "name": "nim",
      "version": "0.1",
      "mimetype": "text/x-nimrod",
      "file_extension": ".nim",
      "pygments_lexer": "",
      "codemirror_mode": "",
      "nbconvert_exporter": "",
    },
    "banner": ""
  }
  
  s.socket.send_wire_msg("kernel_info_reply", m , content, s.key)
  echo "[Nimkernel]: sending kernel info reply and idle"
  spawn s.pub.send("idle") #move to thread

proc handleExecute(shell:Shell,msg:WireMessage) =
  var code = msg.content["code"].str # The code to be executed
  #discard
  echo "[NIMKERNEL]: ",code
  #compiler.execute(code)

proc handle(s:Shell,m:WireMessage) =
  if m.msg_type == Kernel_Info:
    handleKernelInfo(s,m)
  elif m.msg_type == Execute:
    handleExecute(s,m)
  elif m.msg_type == Shutdown :
    echo "[Nimkernel]: kernel wants to shutdown"
  else:
    echo "[Nimkernel]: unhandled message", m

proc receive*(shell:Shell) =
  let recvdmsg : WireMessage = shell.socket.receive_wire_msg()
  echo "[Nimkernel]: sending: ", $recvdmsg.msg_type
  shell.handle(recvdmsg)

