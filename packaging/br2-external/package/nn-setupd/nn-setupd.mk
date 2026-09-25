################################################################################
#
# nn-setupd — BLE setup mode for the byai camera
#
################################################################################

NN_SETUPD_VERSION = local
# Buildroot parses every package's .mk even when the package is off, and a
# local-site package with an empty SITE is a hard error -- which is what a
# defconfig without nn-setupd (nn_byai_toolchain_defconfig) gets, since the
# SRCDIR option only exists while the package is enabled.  Fall back to the
# repo root, the same value the image defconfig sets.
NN_SETUPD_SITE = $(or $(call qstrip,$(BR2_PACKAGE_NN_SETUPD_SRCDIR)),$(BR2_EXTERNAL_NN_PATH)/../..)
NN_SETUPD_SITE_METHOD = local

# The site is the REPO ROOT, and the default work dir (_build) sits inside
# it -- so Buildroot's rsync step copies _build into a build dir that is
# itself inside _build, forever, until the disk or the path length gives
# out.  pkg-generic.mk passes this straight to that rsync.
#
# Leading slashes anchor to the source root on purpose: a nested build/
# inside nn-modules is still copied, only the top-level ones are skipped.
# .git and friends are already handled by Buildroot's RSYNC_VCS_EXCLUSIONS.
NN_SETUPD_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = \
	--exclude=/_build --exclude='/build*' --exclude=/vendor-fw
NN_SETUPD_LICENSE = Apache-2.0
NN_SETUPD_DEPENDENCIES = mbedtls systemd

# Only the setup daemon: this rootfs has no GStreamer, and setup mode runs
# before a camera exists anyway.
NN_SETUPD_CONF_OPTS = -DNN_BUILD_CAMERA=OFF -DNN_BUILD_SETUPD=ON

define NN_SETUPD_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(@D)/nn-setupd.service \
		$(TARGET_DIR)/usr/lib/systemd/system/nn-setupd.service
	# Enabled by default: a freshly flashed card has no other way onto the
	# network, so setup mode has to come up on its own.  The daemon exits
	# 0 once the device is provisioned, so this does not linger.
	mkdir -p $(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants
	ln -sf ../nn-setupd.service \
		$(TARGET_DIR)/usr/lib/systemd/system/multi-user.target.wants/nn-setupd.service
endef

$(eval $(cmake-package))
