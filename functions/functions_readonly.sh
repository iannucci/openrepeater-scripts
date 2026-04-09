#!/bin/bash

################################################################################
# Read-Only Root Filesystem Configuration
# Configures the system to run with a read-only root filesystem,
# tmpfs for volatile directories, and optional USB logging.
################################################################################

function configure_readonly_root {
	echo "--------------------------------------------------------------"
	echo " Configuring Read-Only Root Filesystem"
	echo "--------------------------------------------------------------"

	#############################
	# Disable unnecessary timers
	#############################
	systemctl disable apt-daily.timer apt-daily-upgrade.timer man-db.timer 2>/dev/null

	#############################
	# Journald volatile storage
	#############################
	mkdir -p /etc/systemd/journald.conf.d
	cat > /etc/systemd/journald.conf.d/readonly.conf << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=30M
EOF

	#############################
	# Resolv.conf symlink
	#############################
	ln -sf /run/NetworkManager/resolv.conf /etc/resolv.conf

	#############################
	# Fail2ban systemd backend
	#############################
	mkdir -p /etc/fail2ban/jail.d
	cat > /etc/fail2ban/jail.d/defaults-ro.conf << 'EOF'
[DEFAULT]
backend = systemd
[sshd]
enabled = true
backend = systemd
EOF

	#############################
	# Tmpfiles config
	#############################
	cat > /etc/tmpfiles.d/openrepeater.conf << 'EOF'
# Directories and files on tmpfs at boot for read-only root
d /var/log/nginx 0755 www-data adm -
d /var/log/php 0755 www-data www-data -
f /var/log/svxlink 0644 svxlink daemon -
d /run/php 0755 www-data www-data -
d /var/lib/php/sessions 0733 www-data www-data -
d /var/lib/openrepeater/db 0775 www-data www-data -
d /var/lib/NetworkManager 0755 root root -
f /var/log/auth.log 0640 root adm -
f /var/log/syslog 0640 root adm -
d /var/lib/fail2ban 0755 root root -
EOF

	#############################
	# DB seed service
	#############################
	mkdir -p /opt/openrepeater
	cp /var/lib/openrepeater/db/openrepeater.db /opt/openrepeater/openrepeater.db.seed

	# Move sounds to persistent location and symlink
	if [ -d /var/lib/openrepeater/sounds ]; then
		cp -r /var/lib/openrepeater/sounds /opt/openrepeater/sounds
	fi

	cat > /etc/systemd/system/openrepeater-db.service << 'EOF'
[Unit]
Description=Seed OpenRepeater database and sounds to tmpfs
DefaultDependencies=no
After=local-fs.target systemd-tmpfiles-setup.service
Before=nginx.service php8.2-fpm.service svxlink.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/cp /opt/openrepeater/openrepeater.db.seed /var/lib/openrepeater/db/openrepeater.db
ExecStart=/bin/chown www-data:www-data /var/lib/openrepeater/db/openrepeater.db
ExecStart=/bin/ln -sf /opt/openrepeater/sounds /var/lib/openrepeater/sounds

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable openrepeater-db.service

	#############################
	# Network fallback service
	#############################
	cat > /etc/systemd/system/network-fallback.service << 'EOF'
[Unit]
Description=Network fallback - DHCP if NM fails
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 30
ExecStart=/bin/bash -c 'ip -4 addr show eth0 | grep -q inet || dhclient eth0'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable network-fallback.service

	#############################
	# USB logging service
	#############################
	cat > /usr/local/bin/usb-log-mount << 'SCRIPT'
#!/bin/bash
# Look for a USB drive labeled ORP-LOGS and bind-mount /var/log from it
LABEL="ORP-LOGS"
DEV=$(blkid -L "$LABEL" 2>/dev/null)

if [ -z "$DEV" ]; then
    echo "No USB drive labeled $LABEL found. Logs go to tmpfs (volatile)."
    exit 0
fi

echo "Found $LABEL at $DEV"

# Mount the USB drive (FAT32 for Mac/PC readability)
mkdir -p /run/usb-logs
mount -t vfat -o noatime,uid=0,gid=0,dmask=000,fmask=111 "$DEV" /run/usb-logs

if [ $? -ne 0 ]; then
    echo "Failed to mount $DEV"
    exit 1
fi

# Create log subdirectories
mkdir -p /run/usb-logs/nginx
mkdir -p /run/usb-logs/php
touch /run/usb-logs/svxlink
touch /run/usb-logs/auth.log
touch /run/usb-logs/syslog

# Bind-mount over the tmpfs /var/log
mount --bind /run/usb-logs /var/log

echo "USB logging active on $DEV (FAT32)"
SCRIPT
	chmod +x /usr/local/bin/usb-log-mount

	cat > /etc/systemd/system/usb-logging.service << 'EOF'
[Unit]
Description=Mount USB drive for persistent logging if present
DefaultDependencies=no
After=local-fs.target systemd-tmpfiles-setup.service
Before=nginx.service php8.2-fpm.service svxlink.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/usb-log-mount

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable usb-logging.service

	#############################
	# Helper scripts: rw, ro, save-db
	#############################
	cat > /usr/local/bin/rw << 'EOF'
#!/bin/bash
mount -o remount,rw /
mount -o remount,rw /boot/firmware
echo "Filesystem is now READ-WRITE. Run 'ro' when done."
EOF

	cat > /usr/local/bin/ro << 'EOF'
#!/bin/bash
sync
mount -o remount,ro /boot/firmware
mount -o remount,ro /
echo "Filesystem is now READ-ONLY"
EOF

	cat > /usr/local/bin/save-db << 'EOF'
#!/bin/bash
mount -o remount,rw /
cp /var/lib/openrepeater/db/openrepeater.db /opt/openrepeater/openrepeater.db.seed
sync
mount -o remount,ro /
echo "Database saved to seed."
EOF

	chmod +x /usr/local/bin/rw /usr/local/bin/ro /usr/local/bin/save-db

	#############################
	# Sudoers for rw/ro operations
	#############################
	cat > /etc/sudoers.d/openrepeater-rw << 'EOF'
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/save-db
www-data ALL=(ALL) NOPASSWD: /bin/mount -o remount\,rw /
www-data ALL=(ALL) NOPASSWD: /bin/mount -o remount\,ro /
www-data ALL=(ALL) NOPASSWD: /bin/cp /var/lib/openrepeater/db/openrepeater.db /opt/openrepeater/openrepeater.db.seed
www-data ALL=(ALL) NOPASSWD: /bin/sync
EOF
	chmod 440 /etc/sudoers.d/openrepeater-rw

	#############################
	# Shell prompt indicator
	#############################
	cat >> /etc/bash.bashrc << 'EOF'

# Show filesystem read-only/read-write state in prompt
fs_mode=$(mount | grep ' on / ' | grep -o 'r[ow]')
PS1="[$fs_mode] $PS1"
EOF

	#############################
	# Update fstab for ro root + tmpfs
	#############################
	BOOT_PARTUUID=$(grep '/boot/firmware' /etc/fstab | awk '{print $1}')
	ROOT_PARTUUID=$(grep -E '^\S+\s+/\s' /etc/fstab | awk '{print $1}')

	cat > /etc/fstab << FSTAB
proc            /proc               proc    defaults                            0  0
${BOOT_PARTUUID} /boot/firmware      vfat    defaults,ro                         0  2
${ROOT_PARTUUID} /                   ext4    defaults,noatime,ro                 0  1
tmpfs           /tmp                tmpfs   nosuid,nodev,size=50M               0  0
tmpfs           /var/tmp            tmpfs   nosuid,nodev,size=20M               0  0
tmpfs           /var/log            tmpfs   nosuid,nodev,noexec,size=50M        0  0
tmpfs           /var/spool          tmpfs   nosuid,nodev,noexec,size=10M        0  0
tmpfs           /var/lib/openrepeater tmpfs nosuid,nodev,size=5M                0  0
tmpfs           /var/lib/sudo       tmpfs   nosuid,nodev,noexec,mode=0700,size=1M 0 0
tmpfs           /var/lib/systemd    tmpfs   nosuid,nodev,noexec,size=10M        0  0
tmpfs           /var/lib/nginx      tmpfs   nosuid,nodev,size=5M                0  0
tmpfs           /var/lib/php        tmpfs   nosuid,nodev,size=10M               0  0
tmpfs           /var/lib/NetworkManager tmpfs nosuid,nodev,size=5M              0  0
FSTAB

	#############################
	# Add ro to kernel cmdline
	#############################
	sed -i 's/rootwait/ro rootwait/' /boot/firmware/cmdline.txt

	echo "--------------------------------------------------------------"
	echo " Read-Only Root Configuration Complete"
	echo " System will boot read-only after next reboot."
	echo " Use 'rw' and 'ro' commands to toggle."
	echo " Use 'save-db' to persist database changes."
	echo " Insert FAT32 USB drive labeled 'ORP-LOGS' for persistent logging."
	echo "--------------------------------------------------------------"
}
