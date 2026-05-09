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


# Restore the Fe-Pi mixer state captured from the production W6EI repeater
# (audio/asound.state in this repo) so a freshly rebuilt card comes up with
# the exact same TX/RX audio levels as the live system. The ICS HAT taps
# Fe-Pi Lineout (not Headphone) and Lineout ships muted; this also unmutes.
# Persists state via alsactl store so alsa-restore replays it on every boot,
# including on the read-only root filesystem.
function set_ics_mixer {
	local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	local prod_state="$script_dir/audio/asound.state"
	if [ -f "$prod_state" ]; then
		install -d -m 0755 /var/lib/alsa
		cp "$prod_state" /var/lib/alsa/asound.state
		alsactl restore 0              >/dev/null 2>&1 || true
	else
		# Fallback: minimal unmute if the production state file is missing.
		amixer -c 0 sset Lineout on    >/dev/null 2>&1 || true
		amixer -c 0 sset Lineout 18    >/dev/null 2>&1 || true
	fi

	# Belt-and-suspenders: explicitly force Lineout Playback Switch on,
	# regardless of what the saved state file says. The Fe-Pi codec
	# defaults to Lineout muted at power-on. On the bench card build,
	# the saved asound.state had Lineout=on but somewhere between
	# alsactl restore and the actual codec hardware the switch came
	# back up muted, leaving the system silent. This double-tap is
	# cheap insurance and a no-op when the restore worked correctly.
	# Use both numid and named control because amixer naming has
	# varied across codec driver versions.
	amixer -c 0 sset 'Lineout Playback Switch' on >/dev/null 2>&1 || true
	# numid=11 is the Lineout Playback Switch on sgtl5000-based Fe-Pi cards.
	amixer -c 0 cset numid=11 on >/dev/null 2>&1 || true

	alsactl store 0                    >/dev/null 2>&1 || true
}