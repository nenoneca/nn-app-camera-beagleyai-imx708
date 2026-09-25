################################################################################
#
# nn-sysupd — whole-system A/B OTA agent (layout ab-v1)
#
################################################################################

# Shipped from the nn-modules submodule at the commit this repo pins, so the
# agent and the layout it assumes always come from the same checkout.
NN_SYSUPD_VERSION = local
NN_SYSUPD_SITE = $(BR2_EXTERNAL_NN_PATH)/../../nn-modules/tools/nn-sysupd
NN_SYSUPD_SITE_METHOD = local
NN_SYSUPD_LICENSE = Apache-2.0

define NN_SYSUPD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/nn-sysupd $(TARGET_DIR)/usr/sbin/nn-sysupd
endef

define NN_SYSUPD_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(@D)/nn-sysupd.service \
		$(TARGET_DIR)/usr/lib/systemd/system/nn-sysupd.service
	$(INSTALL) -D -m 0644 $(@D)/nn-sysupd.timer \
		$(TARGET_DIR)/usr/lib/systemd/system/nn-sysupd.timer
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/timers.target.wants
	ln -sf ../nn-sysupd.timer \
		$(TARGET_DIR)/usr/lib/systemd/system/timers.target.wants/nn-sysupd.timer
endef

$(eval $(generic-package))
