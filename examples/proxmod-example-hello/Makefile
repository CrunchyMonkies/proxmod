# The whole build system for a proxmod extension.
#
# Three files land in three directories owned by proxmod or by Debian. Nothing
# is compiled, nothing is generated, and no Proxmox-owned path is touched.

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
	perl -c -Iperl -I../../t/lib perl/ProxmodExample/Hello.pm

install:
	# Loaded by require() inside pvedaemon and pveproxy. /usr/share/perl5 is a
	# Debian vendor directory in perl's default @INC [PVE-F-003], so this works
	# under taint with no path configuration and no PVE-owned directory used.
	$(INSTALL) -d $(DESTDIR)$(PERLDIR)/ProxmodExample
	$(INSTALL_DATA) perl/ProxmodExample/Hello.pm $(DESTDIR)$(PERLDIR)/ProxmodExample/
	# Writing here is what activates proxmod's dpkg trigger. There is no
	# maintainer script in this package, and there does not need to be.
	$(INSTALL) -d $(DESTDIR)$(SHAREDIR)/extensions.d
	$(INSTALL_DATA) conf/50-proxmod-example-hello.conf $(DESTDIR)$(SHAREDIR)/extensions.d/
	# Served unauthenticated under /proxmod/ [PVE-F-023].
	$(INSTALL) -d $(DESTDIR)$(SHAREDIR)/www
	$(INSTALL_DATA) www/proxmod-example-hello.js $(DESTDIR)$(SHAREDIR)/www/

clean:
	rm -rf debian/proxmod-example-hello debian/.debhelper debian/files \
	       debian/*.substvars debian/debhelper-build-stamp
