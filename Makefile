# proxmod — Proxmox VE 9.x extension framework
#
# `install` is the single source of truth for where every shipped file lands;
# debian/rules calls it rather than keeping a second copy of the manifest in
# debian/*.install. Change a path here and the package follows.

SHELL := /bin/sh
PACKAGE := proxmod

DESTDIR ?=
prefix  ?= /usr

# Where proxmod's own code lives. None of these are Proxmox-owned directories,
# which is the whole point: an upgrade of pve-manager cannot touch any of them.
PERLDIR   := $(prefix)/share/perl5
LIBDIR    := $(prefix)/lib/proxmod
SBINDIR   := $(prefix)/sbin
SHAREDIR  := $(prefix)/share/proxmod
UNITDIR   := $(prefix)/lib/systemd/system
MANDIR    := $(prefix)/share/man/man8
DOCDIR    := $(prefix)/share/doc/$(PACKAGE)
SYSCONF   := /etc/proxmod
STATEDIR  := /var/lib/proxmod

INSTALL         := install
INSTALL_PROGRAM := $(INSTALL) -m 0755
INSTALL_DATA    := $(INSTALL) -m 0644

PERL_MODULES := perl/Proxmod.pm $(wildcard perl/Proxmod/*.pm)
# exec/ and bin/ are both mixed sh and Perl, and the lists are explicit rather
# than wildcards, because a file landing in the wrong one means it is never
# linted — or worse, is fed to the wrong linter and the failure gets ignored as
# noise. proxmod-verify replays the API tree and emits JSON, and proxmod-patch
# has to hash files and rewrite them atomically; both are miserable in shell.
# proxmod-exec and proxmod-reapply must run with no interpreter beyond /bin/sh,
# because they run when things are already going wrong.
EXEC_SH      := exec/proxmod-exec exec/proxmod-reapply
EXEC_PERL    := exec/proxmod-patch
EXEC_SCRIPTS := $(EXEC_SH) $(EXEC_PERL)
BIN_SH       := bin/proxmodctl
BIN_PERL     := bin/proxmod-verify
BIN_SCRIPTS  := $(BIN_SH) $(BIN_PERL)
# The maintainer scripts are in here deliberately. They run as root, on every
# host that installs proxmod, at the one moment the package is least able to
# report a problem — an unquoted variable there costs more than anywhere else
# in the tree. They are named rather than globbed because debhelper writes its
# own generated fragments alongside them as debian/proxmod.*.debhelper, and
# linting a build artifact fails on a shebang we did not write.
SHELL_FILES  := $(EXEC_SH) $(BIN_SH) $(wildcard scripts/*.sh) \
                $(wildcard test/qemu/*.sh) $(wildcard test/integration/*.sh) \
                debian/proxmod.preinst debian/proxmod.postinst \
                debian/proxmod.prerm debian/proxmod.postrm
# The example's asset is included deliberately: it is the contract other
# extension authors copy, so a syntax error in it is a defect in ours.
JS_FILES     := $(wildcard www/*.js) $(wildcard examples/*/www/*.js)

# Man pages, and the subset of docs/ that belongs on a host rather than in the
# repository. Two audiences, both of whom are holding an installed package: the
# administrator who has just run `proxmodctl status` and not liked the answer,
# and the author of an extension for this host. Everything else in docs/ — the
# ADRs, the conventions, the PVE fact ledger, the packaging and testing guides —
# is about developing proxmod itself, and is one `git clone` away.
#
# extension-manifest.md is not optional: conf/proxmod.conf is a conffile that
# lands on every host and tells the administrator to read it at exactly this
# path. A promise made by a conffile is a promise the package has to keep.
MAN_PAGES    := man/proxmodctl.8 man/proxmod-verify.8
DOC_FILES    := docs/getting-started.md docs/install.md docs/cli.md \
                docs/troubleshooting.md docs/verification.md \
                docs/compatibility.md docs/security.md docs/patching.md \
                docs/glossary.md \
                docs/extension-manifest.md docs/backend-extensions.md \
                docs/frontend-extensions.md docs/perl-api.md docs/js-api.md

# Vendored upstream Proxmox source. Read-only reference: nothing here is built,
# linted, installed or packaged, and every target above works without it. Note
# that none of the lists above can glob into it — keep it that way, because a
# find-based glob would silently start linting eight upstream repositories.
THIRD_PARTY := docs/third_party

.PHONY: all build install test lint lint-perl lint-shell lint-js deb clean e2e \
        facts facts-src submodules help

all: build

## build: nothing is compiled; this validates that everything at least parses.
build: lint-perl

## install: stage the package into $(DESTDIR). Used by debian/rules.
install:
	$(INSTALL) -d $(DESTDIR)$(PERLDIR)/Proxmod
	$(INSTALL_DATA) perl/Proxmod.pm $(DESTDIR)$(PERLDIR)/Proxmod.pm
	set -e; for m in $(wildcard perl/Proxmod/*.pm); do \
	    $(INSTALL_DATA) "$$m" $(DESTDIR)$(PERLDIR)/Proxmod/; \
	done
	# Injection wrapper and convergence script. These run as root out of
	# systemd and dpkg triggers, so they must stay 0755 — see the
	# override_dh_fixperms note in debian/rules.
	$(INSTALL) -d $(DESTDIR)$(LIBDIR)
	set -e; for s in $(EXEC_SCRIPTS); do $(INSTALL_PROGRAM) "$$s" $(DESTDIR)$(LIBDIR)/; done
	$(INSTALL) -d $(DESTDIR)$(SBINDIR)
	set -e; for s in $(BIN_SCRIPTS); do $(INSTALL_PROGRAM) "$$s" $(DESTDIR)$(SBINDIR)/; done
	# Frontend assets are served unauthenticated under /proxmod/ — never put
	# anything secret here. Extension packages drop their own .js in alongside
	# proxmod-ui.js, which is why postrm prunes this directory with rmdir.
	$(INSTALL) -d $(DESTDIR)$(SHAREDIR)/www
	$(INSTALL_DATA) www/proxmod-ui.js $(DESTDIR)$(SHAREDIR)/www/
	# loader-runtime.js is a template, not an asset: it is read by
	# Proxmod::Frontend and rendered per request into /proxmod/loader.js. It
	# stays out of www/ for two reasons — everything under www/ is served to
	# anyone who can reach :8006, and a browser that fetched the template
	# directly would get the unsubstituted placeholder.
	$(INSTALL_DATA) www/loader-runtime.js $(DESTDIR)$(SHAREDIR)/loader-runtime.js
	# Drop-ins ship here and are copied into /etc/systemd/system by postinst.
	# They are deliberately not conffiles: prerm has to remove the loader
	# before dpkg deletes the module it names.
	# The directory layout is preserved so postinst can copy the tree straight
	# into /etc/systemd/system without knowing any filenames.
	set -e; for u in $(wildcard systemd/*.service.d/*.conf); do \
	    d=$$(basename $$(dirname "$$u")); \
	    $(INSTALL) -d $(DESTDIR)$(SHAREDIR)/systemd/$$d; \
	    $(INSTALL_DATA) "$$u" $(DESTDIR)$(SHAREDIR)/systemd/$$d/; \
	done
	if [ -f systemd/proxmod-verify.service ]; then \
	    $(INSTALL) -d $(DESTDIR)$(UNITDIR); \
	    $(INSTALL_DATA) systemd/proxmod-verify.service $(DESTDIR)$(UNITDIR)/; \
	fi
	# Package-owned extension registry, admin overlay, and patch specs.
	$(INSTALL) -d $(DESTDIR)$(SHAREDIR)/extensions.d
	set -e; for c in $(wildcard conf/*.conf); do \
	    case "$$c" in \
	        conf/proxmod.conf) ;; \
	        *) $(INSTALL_DATA) "$$c" $(DESTDIR)$(SHAREDIR)/extensions.d/ ;; \
	    esac; \
	done
	$(INSTALL) -d $(DESTDIR)$(SHAREDIR)/patches
	set -e; for p in $(wildcard patches/*); do $(INSTALL_DATA) "$$p" $(DESTDIR)$(SHAREDIR)/patches/; done
	$(INSTALL) -d $(DESTDIR)$(SYSCONF)/extensions.d $(DESTDIR)$(SYSCONF)/patches
	if [ -f conf/proxmod.conf ]; then $(INSTALL_DATA) conf/proxmod.conf $(DESTDIR)$(SYSCONF)/proxmod.conf; fi
	$(INSTALL) -d $(DESTDIR)$(STATEDIR)
	# Man pages and the on-host documentation set. debian/rules keeps
	# dh_compress off the .md files so the path conf/proxmod.conf names
	# stays the path that exists.
	$(INSTALL) -d $(DESTDIR)$(MANDIR)
	set -e; for m in $(MAN_PAGES); do $(INSTALL_DATA) "$$m" $(DESTDIR)$(MANDIR)/; done
	$(INSTALL) -d $(DESTDIR)$(DOCDIR)
	set -e; for d in $(DOC_FILES); do $(INSTALL_DATA) "$$d" $(DESTDIR)$(DOCDIR)/; done

## test: unit tests. No Proxmox host required — t/lib holds PVE stubs.
test:
	prove -r t/

## lint: everything that can be checked without a PVE host.
lint: lint-perl lint-shell lint-js

lint-perl:
	@set -e; for m in $(PERL_MODULES) $(BIN_PERL) $(EXEC_PERL); do \
	    [ -e "$$m" ] || continue; \
	    echo "perl -T -c $$m"; \
	    perl -T -Iperl -It/lib -c "$$m" || exit 1; \
	done

# LINT_STRICT turns a missing linter into a failure instead of a skip.
#
# The skips exist so that `make lint` is useful on a machine that has perl and
# nothing else, and that is worth keeping. But they mean a green `make lint`
# proves only that whatever happened to be installed had no complaints — and
# nobody reads two lines of "skipping" as "two thirds of the lint did not run".
# CI and the release workflow set LINT_STRICT=1 so the gate is a gate there,
# where the answer is load-bearing.
LINT_STRICT ?=

# Each recipe line is its own shell, so the "skip" case has to be one
# conditional rather than a guard line followed by the loop.
lint-shell:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
	    if [ -n "$(LINT_STRICT)" ]; then \
	        echo "shellcheck is not installed and LINT_STRICT is set (apt install shellcheck)" >&2; \
	        exit 1; \
	    fi; \
	    echo "shellcheck not installed; skipping (apt install shellcheck)"; \
	else \
	    set -e; for s in $(SHELL_FILES); do \
	        [ -e "$$s" ] || continue; echo "shellcheck $$s"; shellcheck -x "$$s"; \
	    done; \
	fi

# Syntax only — there is no ExtJS to link against here. That is still worth
# doing: these files are injected into a page that has already loaded the
# entire Proxmox interface, so a parse error takes the console with it.
#
# Plus one rule a parser cannot catch: strict mode and callParent are mutually
# exclusive. ExtJS resolves callParent by reading Function.caller on the calling
# method and V8 returns null for that when the caller is strict, so a strict
# initComponent dies inside ext-all.js with "Cannot read properties of null
# (reading 'apply')" — at runtime, in the browser, on the panel it belongs to.
#
# loader-runtime.js is checked in its unsubstituted form on purpose. The
# placeholder is a quoted string, so the template parses as JavaScript before
# Proxmod::Frontend rewrites it; if that ever stops being true the substitution
# is no longer a safe textual one.
lint-js:
	@if ! command -v node >/dev/null 2>&1; then \
	    if [ -n "$(LINT_STRICT)" ]; then \
	        echo "node is not installed and LINT_STRICT is set (apt install nodejs)" >&2; \
	        exit 1; \
	    fi; \
	    echo "node not installed; skipping JS syntax check"; \
	else \
	    set -e; for j in $(JS_FILES); do \
	        [ -e "$$j" ] || continue; echo "node --check $$j"; node --check "$$j"; \
	    done; \
	fi
	@set -e; for j in $(JS_FILES); do \
	    [ -e "$$j" ] || continue; \
	    grep -Eq "^[[:space:]]*['\"]use strict['\"];" "$$j" || continue; \
	    grep -q "callParent\|callSuper" "$$j" || continue; \
	    echo "$$j: 'use strict' breaks ExtJS callParent (Function.caller is null"; \
	    echo "    for a strict caller); drop the directive from this file."; \
	    exit 1; \
	done

## deb: build the binary package into ../ and lint it.
#
# lintian is a gate, not a comment. It used to end in `|| true` on the argument
# that a failing gate nobody can satisfy gets disabled rather than fixed — which
# is true, and the answer to it is to satisfy the gate. The package is clean as
# of 0.2.1; when a tag appears that genuinely does not apply here, override it in
# debian/proxmod.lintian-overrides with a comment saying why, so the next reader
# can disagree with the specific decision instead of with a blanket exemption.
#
# --fail-on error,warning: informational and pedantic tags are advice, and the
# ones that survive a build here are usually about the archive, not the package.
#
# The argument names one file, built from the changelog version, and is not a
# glob. ../ accumulates every version ever built in this checkout, and
# `../$(PACKAGE)_*_all.deb` hands lintian all of them — so the gate reports
# findings that were fixed releases ago, fails a package that is clean, and
# invites the next person to delete old artifacts to make it pass. The same
# mistake is already written up for the example package further down.
#
# The skip below honours LINT_STRICT for the same reason lint-shell does: on a
# developer's machine "no lintian here" is a fair answer, and on the release
# path it is the gate not running. ci.yml and release.yml set it.
deb:
	dpkg-buildpackage -us -uc -b
	@if ! command -v lintian >/dev/null 2>&1; then \
	    if [ -n "$(LINT_STRICT)" ]; then \
	        echo "lintian is not installed and LINT_STRICT is set (apt install lintian)" >&2; \
	        exit 1; \
	    fi; \
	    echo "lintian not installed; skipping (apt install lintian)"; \
	else \
	    lintian --fail-on error,warning ../$(PACKAGE)_$$(dpkg-parsechangelog -S Version)_all.deb; \
	fi

## e2e: full QEMU integration run. Needs PROXMOD_PVE_IMAGE / PROXMOD_PVE_ISO.
e2e:
	./scripts/e2e.sh

## submodules: fetch the vendored Proxmox source into docs/third_party/ (read-only
##             reference for docs/pve-facts.md; no other target needs it).
submodules:
	git submodule update --init --depth 1 --recursive
	@echo "docs/third_party/ populated. Run 'ix map .' to index it, if you use ix."

## facts: re-derive the PVE seam evidence from an installer ISO (no PVE host).
##        make facts ISO=/path/to/proxmox-ve_9.x-1.iso
facts:
	@[ -n "$(ISO)" ] || { echo "usage: make facts ISO=/path/to/proxmox-ve.iso" >&2; exit 2; }
	./scripts/extract-pve-source.sh --iso "$(ISO)" --harvest docs/facts

## facts-src: re-derive the same evidence from docs/third_party/ instead of an ISO.
##            Needs no ISO, and reaches the per-file www/manager6 sources that
##            a packaged PVE has already concatenated away.
facts-src:
	@[ -d $(THIRD_PARTY)/pve-manager/www ] || $(MAKE) submodules
	./scripts/harvest-pve-src.sh docs/facts

# The example is built by CI and by hand often enough that its artifacts
# accumulate here, and a stale .deb is worse than an untidy tree: `lintian
# examples/*_all.deb` picks up every version ever built in this checkout and
# reports findings that were fixed releases ago.
EX_DIR := examples/proxmod-example-hello

clean:
	rm -rf build
	rm -rf debian/$(PACKAGE) debian/.debhelper debian/files debian/*.substvars \
	       debian/debhelper-build-stamp debian/*.debhelper debian/*.debhelper.log
	rm -rf $(EX_DIR)/debian/proxmod-example-hello $(EX_DIR)/debian/.debhelper \
	       $(EX_DIR)/debian/files $(EX_DIR)/debian/*.substvars \
	       $(EX_DIR)/debian/debhelper-build-stamp $(EX_DIR)/debian/*.debhelper \
	       $(EX_DIR)/debian/*.debhelper.log
	rm -f examples/proxmod-example-hello_*.deb \
	      examples/proxmod-example-hello_*.buildinfo \
	      examples/proxmod-example-hello_*.changes

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'
