#!/bin/bash

################################################################################
# DEFINE FUNCTIONS
################################################################################


function set_ics_asound {
	cat > "/etc/asound.conf" << 'DELIM'
ctl.!default {
    type hw
    card 0
}
pcm.dmixed {
    type dmix
    ipc_key 1024
    ipc_key_add_uid 0
    slave.pcm "hw:0,0"
}
pcm.dsnooped {
    type dsnoop
    ipc_key 1025
    slave.pcm "hw:0,0"
}
pcm.duplex {
    type asym
    playback.pcm "dmixed"
    capture.pcm "dsnooped"
}
pcm.shared_left {
    type plug
    slave.pcm "hw:0"
    slave.channels 2
    ttable.0.0 1
}
pcm.shared_right {
    type plug
    slave.pcm "hw:0"
    slave.channels 2
    ttable.1.1 1
}
pcm.left {
    type asym
    playback.pcm "shared_left"
    capture.pcm "dsnooped"
}
pcm.right {
    type asym
    playback.pcm "shared_right"
    capture.pcm "dsnooped"
}
pcm.hw_loopback {
    type hw
    card "Loopback"
    device 1
    subdevice 2
}
pcm.plug_loopback {
    type plug
    slave.pcm "hw_loopback"
    ttable {
        0.0 1
        0.1 1
    }
}
pcm.!default {
    type plug
    slave.pcm "duplex"
}
DELIM
}