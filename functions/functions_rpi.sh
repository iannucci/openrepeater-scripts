#!/bin/bash

################################################################################
#
# DEFINE RPI SPECIFIC FUNCTIONS
#
################################################################################

function rpi_disables {
	echo "--------------------------------------------------------------"
	echo " Disable onboard HDMI sound card not used in OpenRepeater"
	echo "--------------------------------------------------------------"
	#/boot/firmware/config.txt
	sed -i /boot/firmware/config.txt -e"s#dtparam=audio=on#\#dtparam=audio=on#"

	# Disable HDMI audio so Fe-Pi audio codec becomes card 0
	sed -i /boot/firmware/config.txt -e"s#dtoverlay=vc4-kms-v3d\$#dtoverlay=vc4-kms-v3d,noaudio#"
	sed -i /boot/firmware/config.txt -e"s#dtoverlay=vc4-fkms-v3d\$#dtoverlay=vc4-fkms-v3d,noaudio#"

	# /etc/modules
	sed -i /etc/modules -e"s#snd-bcm2835#\#snd-bcm2835#"

	# Bookworm images don't have a default pi user, so no need to remove it
}

################################################################################
