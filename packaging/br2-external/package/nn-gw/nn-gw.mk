################################################################################
#
# nn-gw — camera-hosted Thread gateway (gw_linux + nn-gw-agent)
#
################################################################################

# gw_linux's CMake reaches into ../../modules/libs for fw_common and
# nn_proto, so the site is the nn-modules root (at the commit this repo
# pins) and the package builds its host/gw_linux subdirectory.
NN_GW_VERSION = local
NN_GW_SITE = $(BR2_EXTERNAL_NN_PATH)/../../nn-modules
NN_GW_SITE_METHOD = local
NN_GW_SUBDIR = host/gw_linux
# Skip every build tree that may be sitting in a developer's checkout;
# .git is already excluded by Buildroot's RSYNC_VCS_EXCLUSIONS.
NN_GW_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = \
	--exclude='build*' --exclude='_build' --exclude='cmake-build-*'
NN_GW_LICENSE = Apache-2.0
NN_GW_DEPENDENCIES = mbedtls systemd

NN_GW_PKGDIR = $(BR2_EXTERNAL_NN_PATH)/package/nn-gw

# The CMake install rule puts the binary in bin/; the supervisor and the
# byai agent are ours.
define NN_GW_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/$(NN_GW_SUBDIR)/gw_linux $(TARGET_DIR)/usr/bin/gw_linux
	$(INSTALL) -D -m 0755 $(@D)/$(NN_GW_SUBDIR)/lxc/gw-supervise $(TARGET_DIR)/usr/sbin/gw-supervise
	$(INSTALL) -D -m 0755 $(NN_GW_PKGDIR)/nn-gw-agent $(TARGET_DIR)/usr/sbin/nn-gw-agent
endef

define NN_GW_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(NN_GW_PKGDIR)/nn-gw.service \
		$(TARGET_DIR)/usr/lib/systemd/system/nn-gw.service
	$(INSTALL) -D -m 0644 $(NN_GW_PKGDIR)/nn-gw-agent.service \
		$(TARGET_DIR)/usr/lib/systemd/system/nn-gw-agent.service
	$(INSTALL) -D -m 0644 $(NN_GW_PKGDIR)/nn-gw-agent.timer \
		$(TARGET_DIR)/usr/lib/systemd/system/nn-gw-agent.timer
	# Only the agent's timer is enabled; it starts nn-gw itself when a
	# radio is present and the role is on.
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/timers.target.wants
	ln -sf ../nn-gw-agent.timer \
		$(TARGET_DIR)/usr/lib/systemd/system/timers.target.wants/nn-gw-agent.timer
endef

$(eval $(cmake-package))
