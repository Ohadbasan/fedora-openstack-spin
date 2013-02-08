# fedora-openstack.ks
#
# Description:
# - Fedora OpenStack Spin
#  Installs an OpenStack Environment in a vm
#
# Maintainer(s):
# - Matthias Runge <mrunge@fedoraproject.org>
%include fedora-live-desktop.ks

part / --size 8192 --fstype ext4
part /var/lib/libvirt --size 12288 --fstype ext4

%packages

# The point of a live image is to install
anaconda
isomd5sum
# grub-efi and grub2 and efibootmgr so anaconda can use the right one on install. 
grub-efi
grub2
efibootmgr

# fpaste is very useful for debugging and very small
fpaste

# openstack packages
libvirt-daemon
virt-viewer
novnc
openstack-nova
openstack-nova-common
openstack-nova-novncproxy
openstack-swift
openstack-swift-doc
openstack-swift-proxy
openstack-swift-account
openstack-swift-container
openstack-swift-object
openstack-cinder
openstack-glance
openstack-utils
openstack-dashboard
openstack-quantum
openstack-tempo
openstack-quantum-linuxbridge
openstack-quantum-openvswitch
python-cinder 
python-cinderclient
python-glance
python-nova
python-keystone
python-passlib
openstack-keystone
mysql-server
qpid-cpp-server-daemon
qpid-cpp-server
qpid-cpp-client
memcached 
nbd
sudo
avahi
virt-what
virt-manager
virt-viewer
openssh-server
spice-gtk
gtk-vnc-python
net-tools
libvirt
-libreoffice
%end

%post

# make it so that we don't do writing to the overlay for things which
# are just tmpdirs/caches
mount -t tmpfs -o mode=0755 varcacheyum /var/cache/yum
# also create space for mysql data
mount -t tmpfs -o mode=0755 varlibmysql /var/lib/mysql
chown mysql:mysql /var/lib/mysql
mount -t tmpfs tmp /tmp
mount -t tmpfs vartmp /var/tmp
[ -x /sbin/restorecon ] && /sbin/restorecon /var/cache/yum /tmp /var/tmp >/dev/null 2>&1

# add fedora user with no passwd
action "Adding live user" useradd \$USERADDARGS -c "Live System User" liveuser
echo "liveuser ALL = (ALL) NOPASSWD: ALL" > /etc/sudoers.d/openstack-spin
passwd -d liveuser > /dev/null

# turn off firstboot for livecd boots
systemctl --no-reload disable firstboot-text.service 2> /dev/null || :
systemctl --no-reload disable firstboot-graphical.service 2> /dev/null || :
systemctl stop firstboot-text.service 2> /dev/null || :
systemctl stop firstboot-graphical.service 2> /dev/null || :

# don't use prelink on a running live image
sed -i 's/PRELINKING=yes/PRELINKING=no/' /etc/sysconfig/prelink &>/dev/null || :

# turn off mdmonitor by default
systemctl --no-reload disable mdmonitor.service 2> /dev/null || :
systemctl --no-reload disable mdmonitor-takeover.service 2> /dev/null || :
systemctl stop mdmonitor.service 2> /dev/null || :
systemctl stop mdmonitor-takeover.service 2> /dev/null || :

# don't enable the gnome-settings-daemon packagekit plugin
gsettings set org.gnome.settings-daemon.plugins.updates active 'false' || :

# don't start cron/at as they tend to spawn things which are
# disk intensive that are painful on a live image
systemctl --no-reload disable crond.service 2> /dev/null || :
systemctl --no-reload disable atd.service 2> /dev/null || :
systemctl stop crond.service 2> /dev/null || :
systemctl stop atd.service 2> /dev/null || :

# and hack so that we eject the cd on shutdown if we're using a CD...
if strstr "\`cat /proc/cmdline\`" CDLABEL= ; then
  cat >> /sbin/halt.local << FOE
#!/bin/bash
# XXX: This often gets stuck during shutdown because /etc/init.d/halt
#      (or something else still running) wants to read files from the block\
#      device that was ejected.  Disable for now.  Bug #531924
# we want to eject the cd on halt, but let's also try to avoid
# io errors due to not being able to get files...
#cat /sbin/halt > /dev/null
#cat /sbin/reboot > /dev/null
#/usr/sbin/eject -p -m \$(readlink -f /run/initramfs/livedev) >/dev/null 2>&1
#echo "Please remove the CD from your drive and press Enter to finish restarting"
#read -t 30 < /dev/console
FOE
chmod +x /sbin/halt.local
fi

EOF

# bah, hal starts way too late
cat > /etc/rc.d/init.d/livesys-late << EOF
#!/bin/bash
#
# live: Late init script for live image
#
# chkconfig: 345 99 01
# description: Late init script for live image.

. /etc/init.d/functions

if ! strstr "\`cat /proc/cmdline\`" liveimg || [ "\$1" != "start" ] || [ -e /.liveimg-late-configured ] ; then
    exit 0
fi
exists() {
    which \$1 >/dev/null 2>&1 || return
    \$*
}

touch /.liveimg-late-configured

# read some variables out of /proc/cmdline
for o in \`cat /proc/cmdline\` ; do
    case \$o in
    ks=*)
        ks="--kickstart=\${o#ks=}"
        ;;
    xdriver=*)
        xdriver="\${o#xdriver=}"
        ;;
    esac
done

# if liveinst or textinst is given, start anaconda
if strstr "\`cat /proc/cmdline\`" liveinst ; then
   plymouth --quit
   /usr/sbin/liveinst \$ks
fi
if strstr "\`cat /proc/cmdline\`" textinst ; then
   plymouth --quit
   /usr/sbin/liveinst --text \$ks
fi

# configure X, allowing user to override xdriver
if [ -n "\$xdriver" ]; then
   cat > /etc/X11/xorg.conf.d/00-xdriver.conf <<FOE
Section "Device"
        Identifier      "Videocard0"
        Driver  "\$xdriver"
EndSection
FOE
fi

echo "nbd" > /etc/modules-load.d/nbd.conf
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

systemctl start mysqld.service
mysqladmin password mypwd

cp /usr/bin/openstack-demo-install /tmp
sed -i "s/ROOT_DB_PW=\\\$(getpassword 'database root')/ROOT_DB_PW=\"mypwd\"/" /tmp/openstack-demo-install
./tmp/openstack-demo-install

cp /root/keystonerc /home/liveuser
EOF

chmod 755 /etc/rc.d/init.d/livesys
/sbin/restorecon /etc/rc.d/init.d/livesys
/sbin/chkconfig --add livesys

chmod 755 /etc/rc.d/init.d/livesys-late
/sbin/restorecon /etc/rc.d/init.d/livesys-late
/sbin/chkconfig --add livesys-late

# work around for poor key import UI in PackageKit
rm -f /var/lib/rpm/__db*
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora
echo "Packages within this LiveCD"
rpm -qa
# Note that running rpm recreates the rpm db files which aren't needed or wanted
rm -f /var/lib/rpm/__db*

# go ahead and pre-make the man -k cache (#455968)
/usr/bin/mandb
# save a little bit of space at least...
rm -f /boot/initramfs*
# make sure there aren't core files lying around
rm -f /core*

# convince readahead not to collect
# FIXME: for systemd
%end

# fire up servicesop

%post --nochroot
cp $INSTALL_ROOT/usr/share/doc/*-release-*/GPL $LIVE_ROOT/GPL

# only works on x86, x86_64
if [ "$(uname -i)" = "i386" -o "$(uname -i)" = "x86_64" ]; then
  if [ ! -d $LIVE_ROOT/LiveOS ]; then mkdir -p $LIVE_ROOT/LiveOS ; fi
  cp /usr/bin/livecd-iso-to-disk $LIVE_ROOT/LiveOS
fi
%end

