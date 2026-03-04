include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cloudflared
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI support for Cloudflare Tunnel
LUCI_DEPENDS:=+curl +luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/cloudflared
endef

# include $(TOPDIR)/include/package.mk
