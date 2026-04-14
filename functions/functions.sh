#!/bin/bash

################################################################################
# DEFINE FUNCTIONS
################################################################################

# Absolute path to the openrepeater-scripts repo root. Resolved at source time
# so it stays correct after functions cd into /root or elsewhere. Used by
# apply_svxlink_patches to locate patches/*.patch relative to the scripts dir.
ORP_SCRIPTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"


function check_root {
	if [[ $EUID -ne 0 ]]; then
		echo "--------------------------------------------------------------"
		echo " This script must be run as root...ABORTING!"
		echo "--------------------------------------------------------------"
		exit 1
	else
		echo "--------------------------------------------------------------"
		echo " Looks like you are running as root...Continuing!"
		echo "--------------------------------------------------------------"
	fi	
}

################################################################################

function check_internet {
	wget -q --spider http://google.com
	
	if [ $? -eq 0 ]; then
		echo "--------------------------------------------------------------"
		echo " INTERNET CONNECTION REQUIRED: Connection Found...Continuing!"
		echo "--------------------------------------------------------------"
	else
		echo "--------------------------------------------------------------"
		echo " INTERNET CONNECTION REQUIRED: Not Connection...Aborting!"
		echo "--------------------------------------------------------------"
		exit 1
	fi
}

################################################################################

function check_os {
	# Detects ARM processor (armhf or arm64/aarch64)
	if (dpkg --print-architecture | grep -qE 'armhf|arm64') ; then
		PROCESSOR="ARM"
	else
		PROCESSOR="UNSUPPORTED"
	fi
	
	# Detects Debian Version
	if (grep -q "$REQUIRED_OS_VER." /etc/debian_version) ; then
		DEBIAN_VERSION="$REQUIRED_OS_VER"
	else
		DEBIAN_VERSION="UNSUPPORTED"
	fi

	# Abort if there is a mismatch
	if [ "$PROCESSOR" != "ARM" ] || [ "$DEBIAN_VERSION" != "$REQUIRED_OS_VER" ] ; then
		echo
		echo "**** ERROR ****"
		echo "This script will only work on Debian $REQUIRED_OS_VER ($REQUIRED_OS_NAME) images at this time."
		echo "No other version of Debian is supported at this time. "
		echo "**** EXITING ****"
		exit -1
	fi
}

################################################################################

function check_filesystem {
	PARTITION_SIZE=$(df -m | awk '$1=="/dev/root"{print$2}')
	
	if [ $PARTITION_SIZE -ge $MIN_PARTITION_SIZE ]; then
		# Partition is large enough
		echo "--------------------------------------------------------------"
		echo " Partition Size Looks Good...Continuing!"
		echo "--------------------------------------------------------------"
	else
		# Partition is too small. Show Message
		menu_expand_file_system $MIN_DISK_SIZE
	fi
}

################################################################################

function check_network {
	# Get Eth0 IP for later display
	IP_ADDRESS=$(ip addr show eth0 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1);
}

################################################################################

function wait_for_network {
	echo "--------------------------------------------------------------"
	echo " Waiting for network/internet connection"
	echo "--------------------------------------------------------------"
	
	# Verify network is still up for building over wifi
	echo "Verifying network/internet is still available, please wait..."
	while !(wget -q --spider http://google.com >> /dev/null); do
		echo "Network is down.  Waiting 5 seconds for the network to reconnect..."
		sleep 5s
	done
	echo "Network connected.  Proceeding..."
}

################################################################################

function set_hostname () {
	### SET HOSTNAME ###
	echo "--------------------------------------------------------------"
	echo " Setting Hostname to $1"
	echo "--------------------------------------------------------------"

	sudo hostnamectl set-hostname "$1"
}

################################################################################

# THIS PACKAGE IS OUT OF DATE. USING COMPILE FROM SOURCE INSTEAD

# function install_svxlink_packge {
# 	echo "--------------------------------------------------------------"
# 	echo " Installing SVXLink from Package"
# 	echo "--------------------------------------------------------------"
# 	
# 	# Based on: https://github.com/sm0svx/svxlink/wiki/InstallBinRaspbian
# 	echo 'deb http://mirrordirector.raspbian.org/raspbian/ buster main' | sudo tee /etc/apt/sources.list.d/svxlink.list
# 	apt-get update
# 	
# 	apt-get install svxlink-server
# 	
# 	rm /etc/apt/sources.list.d/svxlink.list
# 	
# 	# Add svxlink user to user groups
# 	usermod -a -G daemon,gpio,audio svxlink
# }

################################################################################

# Apply any patches under patches/*.patch in the openrepeater-scripts
# repo to the current directory (which should be the root of an extracted
# svxlink source tree). Patches are applied with -p0 so their paths must
# be relative to the svxlink source root.
#
# Used by install_svxlink_source after the svxlink tarball is extracted or
# the git clone completes, before cmake configures the build. See
# patches/svxlink-jitter-buffer.patch for the one patch currently shipped.
function apply_svxlink_patches {
	echo "--------------------------------------------------------------"
	echo " Applying ORP patches to svxlink source tree"
	echo "--------------------------------------------------------------"
	local patch_dir="$ORP_SCRIPTS_ROOT/patches"
	if [ ! -d "$patch_dir" ]; then
		echo "  No patches directory found at $patch_dir — skipping"
		return 0
	fi
	local applied=0
	for p in "$patch_dir"/*.patch; do
		[ -f "$p" ] || continue
		echo "  applying $(basename "$p")"
		if ! patch -p0 < "$p"; then
			echo "*** ERROR: failed to apply $(basename "$p")"
			return 1
		fi
		applied=$((applied + 1))
	done
	echo "  $applied patch(es) applied successfully"
	return 0
}

################################################################################

# Overlay site-specific data from the openrepeater-config repo onto the target
# filesystem. Applied AFTER svxlink and ORP have installed their own defaults
# so the overlay wins. Currently used for:
#   - /opt/openrepeater/sounds/*                  (peak-normalized ORP WAVs)
#   - /usr/share/svxlink/sounds/en_US/RSSI/*      (peak-normalized RSSI WAVs)
# Falls back to a no-op if the repo can't be fetched (offline build).
function install_orp_config_overlay {
	echo "--------------------------------------------------------------"
	echo " Overlay data from iannucci/openrepeater-config"
	echo "--------------------------------------------------------------"
	local stage="/tmp/orp-config-overlay"
	rm -rf "$stage"
	if ! git clone --depth 1 https://github.com/iannucci/openrepeater-config.git "$stage"; then
		echo "  WARN: could not clone openrepeater-config — skipping overlay."
		return 0
	fi
	local rs="$stage/running-system"
	if [ ! -d "$rs" ]; then
		echo "  WARN: $rs not found in config repo — skipping overlay."
		rm -rf "$stage"; return 0
	fi

	# ORP-shipped sounds (/opt/openrepeater/sounds)
	if [ -d "$rs/opt/openrepeater/sounds" ]; then
		cp -Rf "$rs/opt/openrepeater/sounds/." /opt/openrepeater/sounds/
		# also mirror into /var/lib/openrepeater/sounds if it exists (ORP
		# runtime path; normal-mode install puts real files there, not a symlink)
		[ -d /var/lib/openrepeater/sounds ] && \
			cp -Rf "$rs/opt/openrepeater/sounds/." /var/lib/openrepeater/sounds/
		echo "  overlaid /opt/openrepeater/sounds"
	fi

	# svxlink-shipped sounds (RSSI tree lives under /usr/share/svxlink)
	if [ -d "$rs/usr/share/svxlink/sounds" ]; then
		cp -Rf "$rs/usr/share/svxlink/sounds/." /usr/share/svxlink/sounds/
		echo "  overlaid /usr/share/svxlink/sounds"
	fi

	chown -R www-data:www-data /usr/share/svxlink/sounds /opt/openrepeater/sounds 2>/dev/null || true

	rm -rf "$stage"
}

################################################################################

# Assert that both ORP patches (diag-logging + jitter-buffer) survived the
# svxlink build. Called from install_svxlink_source after `make install`.
# Exits non-zero on failure so a partially-patched install can't complete.
function verify_svxlink_patches {
	echo "--------------------------------------------------------------"
	echo " Verifying ORP patches present in installed svxlink binaries"
	echo "--------------------------------------------------------------"
	local libdir; libdir="$(dirname "$(ldconfig -p | awk '/libecholib/{print $NF;exit}')")"
	local echolib; echolib=$(ls "$libdir"/libecholib.so.*.*.* 2>/dev/null | head -1)
	local ok=1

	# Diag-logging patch: four log strings added in Squelch/LocalTx/
	# RepeaterLogic/Logic. Check one representative string from each file.
	for marker in \
		'Squelch detector transition' \
		'Squelch (post-debounce)' \
		'Tx control mode set to' \
		'processCommand('; do
		if ! strings /usr/bin/svxlink | grep -qF "$marker"; then
			echo "*** MISSING diag-logging marker: $marker"
			ok=0
		fi
	done

	# Jitter-buffer patch: new methods on EchoLink::Qso.
	if [ -z "$echolib" ] || ! nm -D "$echolib" 2>/dev/null | grep -q jitterBufferInsert; then
		echo "*** MISSING jitter-buffer symbol: jitterBufferInsert in ${echolib:-libecholib}"
		ok=0
	fi

	# Jitter-buffer logging patch: runtime log strings for playout start,
	# periodic tick summary, underrun reset, session summary.
	for marker in \
		'EchoLink JB: playout started' \
		'EchoLink JB: tick' \
		'EchoLink JB: underrun reset' \
		'EchoLink JB: session summary'; do
		if [ -z "$echolib" ] || ! strings "$echolib" 2>/dev/null | grep -qF "$marker"; then
			echo "*** MISSING jitter-buffer-logging marker: $marker"
			ok=0
		fi
	done

	if [ "$ok" -ne 1 ]; then
		echo "*** ERROR: svxlink build is missing required ORP patches."
		echo "*** The bench must be remotely diagnosable — refusing to continue."
		exit 1
	fi
	echo "  OK — diag-logging and jitter-buffer patches both present"
}

################################################################################

function install_svxlink_source () {
	echo "--------------------------------------------------------------"
	echo " Compile/Install SVXLink from Source Code (ver $SVXLINK_VER)"
	echo "--------------------------------------------------------------"
	
	# Based on: https://github.com/sm0svx/svxlink/wiki/InstallSrcDebian

	# Install required packages
 	apt-get update
	apt-get install --assume-yes --fix-missing g++ cmake make libsigc++-2.0-dev libgsm1-dev libpopt-dev tcl-dev \
		libgcrypt20-dev libspeex-dev libasound2-dev libopus-dev librtlsdr-dev doxygen \
		groff alsa-utils vorbis-tools curl git libcurl4-openssl-dev libgpiod-dev libjsoncpp-dev

	# Add svxlink user and add to user groups
	useradd -r svxlink
	usermod -a -G daemon,gpio,audio svxlink

	# Download and compile from source, either the trunk or latest package
	cd "/root"
	echo "svx_trunk=$1"
	if [ "$1" = "svx_trunk" ]; then
		echo "Building SVXLINK from Trunk"
		mkdir svxlink
		cd svxlink
		git clone https://github.com/sm0svx/svxlink.git
		cd svxlink
		apply_svxlink_patches
		cd src

	else
		echo "building svxlink from release version"
		curl -Lo svxlink-source.tar.gz "https://github.com/sm0svx/svxlink/archive/$SVXLINK_VER.tar.gz"
		tar xvzf svxlink-source.tar.gz
		cd svxlink-$SVXLINK_VER
		apply_svxlink_patches
		cd src
	fi

	# If Selected, enable the non-standard modules to be included in the build process
	
	echo "USE_CONTRIBS=$2"
	if [ "$2" = "USE_CONTRIBS" ]; then
		echo "Entering config to enable optional contrib modules"
		Modules_Build_Cmake_switches=' -DWITH_CONTRIB_MODULE_REMOTE_RELAY=ON -DWITH_CONTRIB_MODULE_SITE_STATUS=ON -DWITH_CONTRIB_MODULE_TCLSSTV=ON -DWITH_CONTRIB_MODULE_TXFAN=ON '
	else
		echo "Optional contrib modules not selected"
		Modules_Build_Cmake_switches=""
	fi
	
	mkdir build
	cd build
	echo "make command: cmake -DCMAKE_INSTALL_PREFIX=/usr -DSYSCONF_INSTALL_DIR=/etc -DLOCAL_STATE_DIR=/var -DWITH_SYSTEMD=ON -DUSE_QT=no $Modules_Build_Cmake_switches .."
	cmake -DCMAKE_INSTALL_PREFIX=/usr -DSYSCONF_INSTALL_DIR=/etc -DLOCAL_STATE_DIR=/var -DWITH_SYSTEMD=ON -DUSE_QT=no $Modules_Build_Cmake_switches ..
	
	make -j5
	make doc

	make install
	ldconfig

	# Verify BOTH ORP patches made it into the installed binaries. If either
	# is missing the build is a silent regression — the bench is supposed to
	# be remotely diagnosable, and losing these patches hides all squelch /
	# PTT transitions and the EchoLink jitter buffer. Fail the install loudly
	# rather than produce a half-patched system that looks fine until you
	# try to debug it.
	verify_svxlink_patches

 	# Enable/Disable Services
	systemctl enable svxlink
	systemctl disable remotetrx

	# Clean Up
	#rm /root/svxlink-source.tar.gz
	#rm /root/svxlink-$SVXLINK_VER -R
	rm /root/svxlink* -r -f
}

################################################################################

function fix_svxlink_gpio {
	echo "--------------------------------------------------------------"
	echo " Apply Fixes to SVXLink GPIO Support until corrected"
	echo "--------------------------------------------------------------"
	
	sed -i -e 's/$GPIOPATH/$GPIO_PATH/g' /usr/sbin/svxlink_gpio_up
	
	echo "--------------------------------------------------------------"
	echo " Apply SystemD Fixes to SVXLink GPIO Service"
	echo "--------------------------------------------------------------"
	sed -i /lib/systemd/system/svxlink_gpio_setup.service -e "s#Documentation=man:svxlink(1)#\
	Documentation=man:svxlink(1)\n\
	\#fix to address the gpio not exporting at boot\n\
	Requires=systemd-modules-load.service\n\
	After=systemd-modules.load.service\n\
	After=network.target\n\
	Before=sysvinit.target\n\
	ConditionPathExists=/sys/class/i2c-dev#"

	# Enable the service (disabled by default in SVXLink 24.02)
	systemctl enable svxlink_gpio_setup
}

################################################################################

function install_svxlink_sounds {
	echo "--------------------------------------------------------------"
	echo " Installing ORP Version of SVXLink Sounds (US English)"
	echo "--------------------------------------------------------------"

	cd /root
 	wget https://github.com/OpenRepeater/orp-sounds/archive/2.0.0.zip
	unzip 2.0.0.zip
	mkdir -p $SVXLINK_SOUNDS_DIR
	mv orp-sounds-2.0.0/en_US $SVXLINK_SOUNDS_DIR
	rm -R orp-sounds-2.0.0
	rm 2.0.0.zip
	
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/0.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/phonetic_0.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/1.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/phonetic_1.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/2.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/phonetic_2.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/3.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/phonetic_3.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/4.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/phonetic_4.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/5.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/phonetic_5.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/6.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/phonetic_6.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/7.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/phonetic_7.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/8.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/phonetic_8.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/9.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/phonetic_9.wav"	
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/O.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/oX.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/MetarInfo/hours.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/hours.wav"
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/MetarInfo/hour.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/hour.wav"

	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Default/Hz.wav" "$SVXLINK_SOUNDS_DIR/en_US/Core/hz.wav"
	
	ln -s "$SVXLINK_SOUNDS_DIR/en_US/Core/repeater.wav" "$SVXLINK_SOUNDS_DIR/en_US/Default/repeater.wav"
}

################################################################################

function enable_i2c {
	echo "--------------------------------------------------------------"
	echo " Enable I2C bus and I2C Devices"
	echo "--------------------------------------------------------------"

	apt-get install --assume-yes --fix-missing i2c-tools

	sed -i /boot/firmware/config.txt -e "s#\#dtparam=i2c_arm=on#dtparam=i2c_arm=on#"
	echo "i2c-dev" >> /etc/modules
}
################################################################################

function config_ics_controllers {
	echo "--------------------------------------------------------------"
	echo " Enable ICS Controller intergrations"
	echo "--------------------------------------------------------------"

	cat >> /boot/firmware/config.txt <<- DELIM
		#Enable FE-Pi Overlay
		dtoverlay=fe-pi-audio
		dtoverlay=i2s-mmap

		#Enable mcp23s17 Overlay
		dtoverlay=mcp23017,addr=0x20,gpiopin=12
		
		#Enable mcp3008 adc overlay
		dtoverlay=mcp3008:spi0-0-present,spi0-0-speed=3600000

		# Enable UART for serial console
		enable_uart=1
		DELIM
}

################################################################################

function install_webserver {
	echo "--------------------------------------------------------------"
	echo " Installing NGINX and PHP"
	echo "--------------------------------------------------------------"
	apt-get install --assume-yes --fix-missing nginx;
	apt-get install --assume-yes --fix-missing memcached ssl-cert \
		php-common php-fpm php-common php-curl php-dev php-gd php-imagick \
		php-memcached php-pspell php-snmp php-sqlite3 php8.2-xml php-pear php-ssh2 php-cli php-zip
	
	apt-get clean
	
	echo "--------------------------------------------------------------"
	echo " Backup original config files"
	echo "--------------------------------------------------------------"
	cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
	cp /etc/php/8.2/fpm/php-fpm.conf /etc/php/8.2/fpm/php-fpm.conf.orig
	cp /etc/php/8.2/fpm/php.ini /etc/php/8.2/fpm/php.ini.orig
	cp /etc/php/8.2/fpm/pool.d/www.conf /etc/php/8.2/fpm/pool.d/www.conf.orig
	
	echo "--------------------------------------------------------------"
	echo " Installing self signed SSL certificate"
	echo "--------------------------------------------------------------"
	cp -r /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/private/nginx.key
	cp -r /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/ssl/certs/nginx.crt
	
	echo "--------------------------------------------------------------"
	echo " Changing file upload size from 2M to $UPLOAD_SIZE"
	echo "--------------------------------------------------------------"
	sed -i "$PHP_INI" -e "s#upload_max_filesize = 2M#upload_max_filesize = $UPLOAD_SIZE#"
	
	# Changing post_max_size limit from 8M to UPLOAD_SIZE
	sed -i "$PHP_INI" -e "s#post_max_size = 8M#post_max_size = $UPLOAD_SIZE#"
	
	echo "--------------------------------------------------------------"
	echo " Enabling memcache in php.ini"
	echo "--------------------------------------------------------------"
	cat >> "$PHP_INI" <<- DELIM 
		extensions=memcached.so 
		DELIM
	
	echo "--------------------------------------------------------------"
	echo " Setup NGINX Site Config File for OpenRepeater UI"
	echo "--------------------------------------------------------------"

	rm -rf /etc/nginx/sites-enabled/default
	ln -sf /etc/nginx/sites-available/"$GUI_NAME" /etc/nginx/sites-enabled/"$GUI_NAME"
	
	# Nginx Config File
	cat > /etc/nginx/sites-available/$GUI_NAME  <<- 'DELIM'
		server {
		   listen  80;
		   listen [::]:80 default_server ipv6only=on;
		   if ($ssl_protocol = "") {
		      rewrite     ^   https://$server_addr$request_uri? permanent;
		   }
		}
		
		server {
		   listen 443;
		   listen [::]:443 default_server ipv6only=on;
		   
		   include snippets/snakeoil.conf;
		   ssl  on;
		   
		   root /var/www/openrepeater;
		   index index.php;
		   
		   error_page 404 /404.php;
		   
		   client_max_body_size 25M;
		   client_body_buffer_size 128k;
		   
		   access_log /var/log/nginx/access.log;
		   error_log /var/log/nginx/error.log;
		   
		   location ~ \.php$ {
		      include snippets/fastcgi-php.conf;
		      include fastcgi_params;
		      fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
		      fastcgi_param   SCRIPT_FILENAME /var/www/openrepeater/$fastcgi_script_name;
		      error_page  404   404.php;
		      fastcgi_intercept_errors on;		
		   }
		   
		   # Disable viewing .htaccess & .htpassword & .db
		   location ~ .htaccess {
		      deny all;
		   }
		   location ~ .htpassword {
		      deny all;
		   }
		   location ~^.+.(db)$ {
		      deny all;
		   }
		}
	DELIM


	echo "--------------------------------------------------------------"
	echo " Make sure WWW dir is owned by web server"
	echo "--------------------------------------------------------------"
	# Create Temp Folder UI. Will later be replaced.
	mkdir "$WWW_PATH/$GUI_NAME"
	echo "Future home of ORP" > $WWW_PATH/$GUI_NAME/index.php

	# Change permissions
	chown -R www-data:www-data "$WWW_PATH/$GUI_NAME"
	
	echo "--------------------------------------------------------------"
	echo " Restarting NGINX and PHP"
	echo "--------------------------------------------------------------"
	for i in nginx php-fpm ;do service "${i}" restart > /dev/null 2>&1 ; done	
}

################################################################################

function install_orp_dependancies {
	echo "--------------------------------------------------------------"
	echo " Installing OpenRepeater/SVXLink Dependencies"
	echo "--------------------------------------------------------------"

	apt-get install --assume-yes --fix-missing alsa-utils bzip2 cron dialog fail2ban flite gawk \
		git-core gpsd gpsd-clients i2c-tools install-info libasound2 libasound2-plugin-equal \
		libgcrypt20 libgsm1 libopus0 libpopt0 libsigc++-2.0-0v5 libsox-fmt-mp3 libxml2 libxml2-dev \
		libxslt1-dev logrotate ntp python3-configobj python3-dev \
		python3-pip python3-usb python3-serial screen sox sqlite3 \
		sudo tcl8.6 time tk8.6 usbutils uuid vim vorbis-tools watchdog wvdial

	# w3rcr -> network-manager package was removed as it caused instability 
	# particularly with wifi networks. This is a packaged geared towards laptop
        # users who constant change their connection
	# This fixes issues:
	#   https://github.com/OpenRepeater/scripts/issues/20
	#   https://github.com/OpenRepeater/scripts/issues/21
	#
	# If this is needed down the road prior to the installation put entry in
	# config file in /etc/NetworkManager/conf.d.
	# [device]
	# wifi.scan-rand-mac-address=no
	# ethernet.scan-rand-mac-address=no
}

################################################################################

function install_orp_from_github {
	echo "--------------------------------------------------------------"
	echo " Installing OpenRepeater files from GitHub repo (Clone)"
	echo "--------------------------------------------------------------"

	rm -rf $WWW_PATH/$GUI_NAME/*
	cd $WWW_PATH
	git clone -b 2.1.3-bookworm --single-branch https://github.com/iannucci/openrepeater.git $WWW_PATH/$GUI_NAME

	# Layer 1 (always): stamp the deployed-commit short SHA into .git-sha
	# so the footer can display it. Captured NOW, before the .git/ tree
	# may be removed below in the NORMAL branch.
	( cd "$WWW_PATH/$GUI_NAME" && \
	  git rev-parse --short HEAD > .git-sha && \
	  chmod 0644 .git-sha )

	# Layer 2 (dev only): install git hooks that refresh .git-sha after any
	# subsequent local git pull / checkout. In NORMAL mode .git/ is removed
	# below, so hooks would be wiped — use the build-time stamp from Layer 1.
	if [ "$ORP_FILE_LOCATIONS" = "dev" ]; then
		for h in post-merge post-checkout; do
			cat > "$WWW_PATH/$GUI_NAME/.git/hooks/$h" <<'HOOK'
#!/bin/sh
git rev-parse --short HEAD > .git-sha
HOOK
			chmod 0755 "$WWW_PATH/$GUI_NAME/.git/hooks/$h"
		done
	fi

	if [ $ORP_FILE_LOCATIONS = "dev" ]; then
		#######################################################################
		# DEVELOPER SETUP: LINK FILES INTO PLACE FOR GITHUB SYNC
		#######################################################################

		# DEV LINKING: Database
		mkdir -p "/var/lib/openrepeater/db"
		ln -sf "$WWW_PATH/$GUI_NAME/install/sql/openrepeater.db" "/var/lib/openrepeater/db/openrepeater.db"
		mkdir -p "/etc/openrepeater"
	
		# DEV LINKING: ORP Sounds (Courtesy Tones / Sample IDs)
		ln -s "$WWW_PATH/$GUI_NAME/install/sounds" "$WWW_PATH/$GUI_NAME/sounds"
		ln -s "$WWW_PATH/$GUI_NAME/install/sounds" "/var/lib/openrepeater/sounds"
	
		# DEV LINKING: ORP Helper Bash Script
		ln -s "$WWW_PATH/$GUI_NAME/install/scripts/orp_helper" "/usr/sbin/orp_helper"
		
		# DEV LINKING: Link ORP into SVXLink directories
		ln -s "/etc/svxlink" "/etc/openrepeater/svxlink"
		mkdir -p "/etc/openrepeater/svxlink/local-events.d"	
	
		#Link ORP to SVXLink log
		ln -s "/var/log/svxlink" "/var/www/openrepeater/log"
	
		# DEV LINKING: Dev Test Folder
		ln -s "$WWW_PATH/$GUI_NAME/install/dev" "$WWW_PATH/$GUI_NAME/dev"


	else
		#######################################################################
		# NORMAL SETUP: PLACE FILES WHERE THEY SHOULD BE 
		#######################################################################

		# MOVE: Database
		mkdir -p "/var/lib/openrepeater/db"
		mv "$WWW_PATH/$GUI_NAME/install/sql/openrepeater.db" "/var/lib/openrepeater/db/openrepeater.db"
		mkdir -p "/etc/openrepeater"
		
		# MOVE: ORP Sounds (Courtesy Tones / Sample IDs)
		mv "$WWW_PATH/$GUI_NAME/install/sounds" "/var/lib/openrepeater/sounds"
		ln -s "/var/lib/openrepeater/sounds" "$WWW_PATH/$GUI_NAME/sounds"
		
		# MOVE: ORP Helper Bash Script
		mv "$WWW_PATH/$GUI_NAME/install/scripts/orp_helper" "/usr/sbin/orp_helper"
		
		# LINKING: Link ORP into SVXLink directories
		ln -s "/etc/svxlink" "/etc/openrepeater/svxlink"
		mkdir -p "/etc/openrepeater/svxlink/local-events.d"	
		
		# LINKING: Link ORP to SVXLink log
		ln -s "/var/log/svxlink" "/var/www/openrepeater/log"
		
		# REMOVE: Cleanup install folders/files
		rm -R "$WWW_PATH/$GUI_NAME/debian"
		rm -R "$WWW_PATH/$GUI_NAME/install"
		rm "$WWW_PATH/$GUI_NAME/README.md"
		rm /var/www/openrepeater/dev
		rm -R /var/www/openrepeater/.git*

	fi


	# FIX PERMISSIONS/OWNERSHIP
	chown www-data:www-data "$WWW_PATH/$GUI_NAME" -R

	chown www-data:www-data "/etc/openrepeater" -R
	chown www-data:www-data "/etc/svxlink" -R
	chown www-data:www-data "/usr/share/svxlink/events.d/" -R
	chown www-data:www-data "/usr/share/svxlink/modules.d/" -R
	chown www-data:www-data "/usr/share/svxlink/sounds/" -R

	chown www-data:www-data "/var/lib/openrepeater/" -R
	chmod 777 "/var/lib/openrepeater/" -R

	# Reset database...just in case it contains callsign info.
	sqlite3 "/var/lib/openrepeater/db/openrepeater.db" "UPDATE settings SET value='' WHERE keyID='callSign'"
	sqlite3 "/var/lib/openrepeater/db/openrepeater.db" "UPDATE modules SET moduleEnabled='0', moduleOptions='' WHERE svxlinkName='EchoLink'"

	# Install default ORP RepeaterLogic TCL event handler.
	# This defines the ORP_RepeaterLogic_Port1 namespace with all required
	# event procs (every_second, repeater_up/down, etc.). Without it, SVXLink
	# logs errors every second. Gets regenerated by "Rebuild & Restart".
	if [ -f "$WWW_PATH/$GUI_NAME/install/tcl/ORP_RepeaterLogic_Port1.tcl" ]; then
		cp "$WWW_PATH/$GUI_NAME/install/tcl/ORP_RepeaterLogic_Port1.tcl" /usr/share/svxlink/events.d/
	fi
}

################################################################################

function install_orp_from_package {
	echo "ORP Package install code goes here"
}

################################################################################

### THIS FUNCTION IS BEING DEPRECIATED ###
function install_orp_modules {
	echo "--------------------------------------------------------------"
	echo " Installing OpenRepeater custom SVXLink Modules"
	echo "--------------------------------------------------------------"

	### Install ORP Remote Relay Module
	cd /root
	curl -sSLo remote_relay.zip https://github.com/OpenRepeater/MODULE_Remote_Relay/archive/${ORP_RMT_RELAY_BRANCH}.zip
	unzip remote_relay.zip
	BASE_DIR=MODULE_Remote_Relay-${ORP_RMT_RELAY_BRANCH}
	cp ${BASE_DIR}/svxlink/events.d/RemoteRelay.tcl /usr/share/svxlink/events.d/RemoteRelay.tcl
	cp ${BASE_DIR}/svxlink/modules.d/ModuleRemoteRelay.tcl /usr/share/svxlink/modules.d/ModuleRemoteRelay.tcl
	rm -R ${BASE_DIR}
	rm remote_relay.zip
}

################################################################################

function install_custom_modules {
	echo "--------------------------------------------------------------"
	echo " Installing custom modules vendored in the ORP web UI fork"
	echo "--------------------------------------------------------------"

	# Modules that ship as a directory under $WWW_PATH/$GUI_NAME/modules/<Name>/
	# with a svxlink/ subtree containing events.d/, modules.d/, and (optionally)
	# sounds/en_US/ files. Each module's SVXLink-side files get installed into
	# /usr/share/svxlink/{events.d,modules.d,sounds/en_US/<Name>}.

	### RSSI module (Bob Iannucci, W6EI)
	local RSSI_SRC="$WWW_PATH/$GUI_NAME/modules/RSSI/svxlink"
	if [ -d "$RSSI_SRC" ]; then
		cp "$RSSI_SRC/events.d/RSSI.tcl"        /usr/share/svxlink/events.d/RSSI.tcl
		cp "$RSSI_SRC/modules.d/ModuleRSSI.tcl" /usr/share/svxlink/modules.d/ModuleRSSI.tcl
		mkdir -p /usr/share/svxlink/sounds/en_US/RSSI
		cp -R "$RSSI_SRC/sounds/en_US/." /usr/share/svxlink/sounds/en_US/RSSI/
		chown -R www-data:www-data \
			/usr/share/svxlink/events.d/RSSI.tcl \
			/usr/share/svxlink/modules.d/ModuleRSSI.tcl \
			/usr/share/svxlink/sounds/en_US/RSSI

		# Register the module in the seed database (disabled by default, empty
		# options). Bob's live-system DB backup already contains a populated
		# RSSI row — this INSERT only affects fresh builds with no backup.
		sqlite3 /var/lib/openrepeater/db/openrepeater.db \
			"INSERT OR IGNORE INTO modules (moduleEnabled, svxlinkName, svxlinkID, moduleOptions) VALUES (0, 'RSSI', 3, '');"
	else
		echo "WARNING: RSSI module source not found at $RSSI_SRC"
	fi
}

################################################################################

function finalize_svxlink_ownership {
	# Final ownership pass on /etc/svxlink. install_orp_from_github already
	# chowns this tree, but svxlink's `make install` (in install_svxlink_source,
	# run earlier) leaves some of the default svxlink.d/*.conf files owned by
	# svxlink:daemon depending on build timing — forensic investigation of a
	# completed build showed ModuleDtmfRepeater.conf, ModuleFrn.conf,
	# ModuleMetarInfo.conf, ModulePropagationMonitor.conf, ModuleSelCallEnc.conf,
	# ModuleTclVoiceMail.conf, and ModuleTrx.conf ended up svxlink:daemon,
	# which blocks ORP's php-fpm process (running as www-data) from rewriting
	# them on "Rebuild & Restart" with a Permission denied error.
	#
	# This is a belt-and-suspenders idempotent fix at the end of the build.
	echo "--------------------------------------------------------------"
	echo " Final ownership pass on /etc/svxlink"
	echo "--------------------------------------------------------------"
	chown -R www-data:www-data /etc/svxlink
}

################################################################################

function install_svxlink_audio_observability {
	# Audio-pipeline reliability and observability:
	#
	#   1. Drop a systemd override that runs svxlink at SCHED_FIFO priority 50
	#      (Nice=-20, LimitRTPRIO=99, LimitMEMLOCK=infinity, IOSchedulingClass=
	#      realtime). The default svxlink unit has LimitRTPRIO=0, which prevents
	#      the audio thread from ever escaping standard time-sharing scheduling
	#      and produces audible glitches on Pi 4 hardware under any non-trivial
	#      load. Bench measurement (Phase 4 of the W6EI investigation) showed a
	#      22x improvement in worst-case wake-up jitter under load with this
	#      override applied. See iannucci/aredn-network-analysis for the data.
	#
	#   2. Install svxlink-audio-monitor as a systemd service. Always-on
	#      observability daemon polling /proc/asound/card0/pcm0[pc]/sub0/status
	#      at 200 Hz; writes a JSONL event log only when something interesting
	#      happens (TX keyup, TX dekey, real or near XRUN events). Runs at
	#      Nice=10 / IOSchedulingClass=idle so it cannot interfere with svxlink.
	#
	#   3. Install svxlink-audio-report as the summarizer for the JSONL log.
	#
	#   4. Wire up daily log rotation (7 days retention, compressed).
	#
	# All source files live in audio/ under this scripts repo.
	echo "--------------------------------------------------------------"
	echo " Installing svxlink audio reliability + observability"
	echo "--------------------------------------------------------------"

	# 1. Real-time priority drop-in for svxlink.service
	mkdir -p /etc/systemd/system/svxlink.service.d
	install -m 0644 "$ORP_SCRIPTS_ROOT/audio/realtime.conf" \
		/etc/systemd/system/svxlink.service.d/realtime.conf

	# 2. Audio monitor binary + service
	install -m 0755 "$ORP_SCRIPTS_ROOT/audio/svxlink-audio-monitor.py" \
		/usr/local/bin/svxlink-audio-monitor.py
	install -m 0644 "$ORP_SCRIPTS_ROOT/audio/svxlink-audio-monitor.service" \
		/etc/systemd/system/svxlink-audio-monitor.service

	# 3. Audio report tool (drops .py extension for cleaner CLI use)
	install -m 0755 "$ORP_SCRIPTS_ROOT/audio/svxlink-audio-report.py" \
		/usr/local/bin/svxlink-audio-report

	# 4. Logrotate config for the audio monitor
	install -m 0644 "$ORP_SCRIPTS_ROOT/audio/svxlink-audio-monitor.logrotate" \
		/etc/logrotate.d/svxlink-audio-monitor

	# Make sure the log file exists with correct ownership
	touch /var/log/svxlink-audio-monitor.jsonl
	chmod 0644 /var/log/svxlink-audio-monitor.jsonl

	# 4a. svxlink's own log (/var/log/svxlink) has no default
	#     logrotate config; add one. Particularly relevant once the
	#     diagnostic-logging patch (patches/svxlink-diag-logging.patch)
	#     adds routine transition events.
	install -m 0644 "$ORP_SCRIPTS_ROOT/audio/svxlink.logrotate" \
		/etc/logrotate.d/svxlink

	# 5. GPIO squelch edge monitor — independent edge-triggered
	#    observability of the RX squelch GPIO pin. Hunts the
	#    "user keys up but repeater doesn't respond" failure mode
	#    by detecting GPIO edges the kernel signals via sysfs
	#    POLLPRI (microsecond latency), vs svxlink's own 100 ms
	#    polled reader which can miss edges when its single thread
	#    stalls. Correlate the two logs with svxlink-gpio-vs-log.
	install -m 0755 "$ORP_SCRIPTS_ROOT/audio/svxlink-gpio-monitor.py" \
		/usr/local/bin/svxlink-gpio-monitor.py
	install -m 0755 "$ORP_SCRIPTS_ROOT/audio/svxlink-gpio-vs-log.py" \
		/usr/local/bin/svxlink-gpio-vs-log
	install -m 0644 "$ORP_SCRIPTS_ROOT/audio/svxlink-gpio-monitor.service" \
		/etc/systemd/system/svxlink-gpio-monitor.service
	install -m 0644 "$ORP_SCRIPTS_ROOT/audio/svxlink-gpio-monitor.logrotate" \
		/etc/logrotate.d/svxlink-gpio-monitor
	touch /var/log/svxlink-gpio-monitor.jsonl
	chmod 0644 /var/log/svxlink-gpio-monitor.jsonl

	# Pick up the unit changes and enable the new monitor units
	systemctl daemon-reload
	systemctl enable svxlink-audio-monitor.service
	systemctl enable svxlink-gpio-monitor.service

	echo "  installed: svxlink RT priority drop-in"
	echo "  installed: svxlink-audio-monitor.service (will start at boot)"
	echo "  installed: svxlink-audio-report (CLI summarizer)"
	echo "  installed: svxlink-gpio-monitor.service (will start at boot)"
	echo "  installed: svxlink-gpio-vs-log (GPIO vs svxlink-log correlator)"
	echo "  installed: /etc/logrotate.d/svxlink-audio-monitor"
	echo "  installed: /etc/logrotate.d/svxlink-gpio-monitor"
}

################################################################################

function modify_sudoers {
	echo "--------------------------------------------------------------"
	echo " Setting up sudoers permissions for OpenRepeater"
	echo "--------------------------------------------------------------"
	cat >> "/etc/sudoers" <<- DELIM
		# OPENREPEATER: allow www-data to access orp_helper
		www-data   ALL=(ALL) NOPASSWD: /usr/sbin/orp_helper
		www-data   ALL=(ALL) NOPASSWD: /bin/systemctl restart svxlink
		www-data   ALL=(ALL) NOPASSWD: /bin/systemctl stop svxlink
		www-data   ALL=(ALL) NOPASSWD: /bin/systemctl start svxlink
		www-data   ALL=(ALL) NOPASSWD: /usr/local/bin/save-db
		www-data   ALL=(ALL) NOPASSWD: /bin/mount -o remount\,rw /
		www-data   ALL=(ALL) NOPASSWD: /bin/mount -o remount\,ro /
		www-data   ALL=(ALL) NOPASSWD: /bin/cp /var/lib/openrepeater/db/openrepeater.db /opt/openrepeater/openrepeater.db.seed
		www-data   ALL=(ALL) NOPASSWD: /bin/sync
		DELIM
}

################################################################################

function install_logrotate_config {
	echo "--------------------------------------------------------------"
	echo " Installing logrotate config for OpenRepeater"
	echo "--------------------------------------------------------------"
	cat > /etc/logrotate.d/openrepeater << 'DELIM'
# Logrotate config for OpenRepeater
# Keeps logs bounded so USB logging drive doesn't fill up

/var/log/svxlink {
    weekly
    rotate 4
    maxsize 10M
    missingok
    notifempty
    copytruncate
}

/var/log/nginx/access.log {
    weekly
    rotate 4
    maxsize 10M
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 $(cat /run/nginx.pid) 2>/dev/null || true
    endscript
}

/var/log/nginx/error.log {
    weekly
    rotate 4
    maxsize 5M
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 $(cat /run/nginx.pid) 2>/dev/null || true
    endscript
}

/var/log/auth.log /var/log/syslog {
    weekly
    rotate 4
    maxsize 5M
    missingok
    notifempty
    copytruncate
}
DELIM
}

################################################################################

function update_versioning {
	echo "--------------------------------------------------------------"
	echo " Setting ORP Build Version"
	echo "--------------------------------------------------------------"

	# Update version in database
	sqlite3 "/var/lib/openrepeater/db/openrepeater.db" "UPDATE version_info SET version_num='$ORP_VERSION'"
}

function logic_fixup {

	# change to the top level directory
	cd /
	
	#find the desired function
	
	InputFileName=$1
	if [ -z "$InputFileName" ]; then
	  echo "parameter 'InputFileName' was not entered"
	  echo "Usage= ./Logic_fixup.sh <input file path> \"proc <function name>\" <output file path>"
	  echo "it is assumed the input file path is an absolute path"
	  return -1
	fi  
	if  ! [ -f $InputFileName  ]; then
	  echo "parameter \'InputFileName\' is not a valid file path"
	  echo "it is assumed the input file path is an absolute path"
	  return -1
	else
	  echo "$InputFileName is a valid path"
	fi

	FunctionName=$2
	if [ -z "$FunctionName" ]; then
	  echo "parameter 'FunctionName' was not entered"
	  return -1
	else
	  echo "FunctionName is '$FunctionName'"
	fi

	OutputFileName=$3
	if [ -z "$OutputFileName" ]; then
	  echo "parameter 'OutputFileName' was not entered"
	else
	  echo "OutputFileName is $OutputFileName"
	fi


	#Locate the begining of the function
	file="$InputFileName"
	StartLine=1
	while IFS= read -r line
	do
	#echo $line
	  
	  if [[ $line == *"$FunctionName"* ]]; then
		break
	  fi
	  ((StartLine++))
	done <"$file"
	echo "StartLine: $StartLine"

	#Locate the start of the next function
	NextStart=0
	while IFS= read -r line
	do
	  #make sure we are not looking in the wrong place
	  if (($NextStart > (($StartLine )))) && [[ $line == *"proc "* ]]; then
		break;
	  fi
	  ((NextStart++))
	done <"$file"
	echo "NextStart: $NextStart"

	# we should now have the starting line of the desired function, and the start of the next function.
	# Now we need to comment out the respective lines of code leaving the desired function effectively
	# empty
	CurrentLine=0

	# process the file
	while IFS= read -r line
	do
	  #echo $CurrentLine
	  if  (( $CurrentLine >= $StartLine )) && [[ $line != '}' ]] && [[ $line != "" ]] && [[ ${line:0:1} != '#' ]] && [[ (($CurrentLine < $NextStart)) ]]; then   

		echo "#$line" >> "$OutputFileName"".tmp"
	  else
		echo "$line" >> "$OutputFileName"".tmp"
	  fi
	  
	  ((CurrentLine++))
	done <"$file"
	
	mv "$OutputFileName"".tmp" "$OutputFileName"

}


