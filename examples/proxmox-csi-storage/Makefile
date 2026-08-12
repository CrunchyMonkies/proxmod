# Build system for the proxmox-csi-storage proxmod extension.
#
# One Perl module, one manifest. Nothing is compiled or generated, and no
# Proxmox-owned path is touched.

DESTDIR ?=
prefix  ?= /usr

PERLDIR  := $(prefix)/share/perl5
SHAREDIR := $(prefix)/share/proxmod

INSTALL      := install
INSTALL_DATA := $(INSTALL) -m 0644

.PHONY: all build install clean

all: build

# Nothing to build; check that the module at least parses.
build:
	perl -c -Iperl -I../../t/lib perl/ProxmodExt/CSIStorage.pm

install:
	$(INSTALL) -d $(DESTDIR)$(PERLDIR)/ProxmodExt
	$(INSTALL_DATA) perl/ProxmodExt/CSIStorage.pm $(DESTDIR)$(PERLDIR)/ProxmodExt/
	# Writing here activates proxmod's dpkg trigger; no maintainer script
	# needed.
	$(INSTALL) -d $(DESTDIR)$(SHAREDIR)/extensions.d
	$(INSTALL_DATA) conf/50-proxmox-csi-storage.conf $(DESTDIR)$(SHAREDIR)/extensions.d/

clean:
	rm -rf debian/proxmox-csi-storage debian/.debhelper debian/files \
	       debian/*.substvars debian/debhelper-build-stamp
