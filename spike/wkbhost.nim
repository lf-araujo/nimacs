## Host API stubs: the signatures config scripts compile against. Real behaviour
## is bound by the host at VM runtime via implementRoutine.
proc status*(msg: string) = discard
proc bindkey*(chord, command: string) = discard
proc defcommand*(name, label, procName: string) = discard
proc runAsync*(cmd, callbackProc: string) = discard
