/*
 * proxmod-ui.js — the JavaScript half of the extension contract.
 *
 * Loaded by /proxmod/loader.js before any extension asset, and always first.
 * Everything an extension is allowed to touch in the web interface is reached
 * through the single global `Proxmod` created here.
 *
 * Three things about the environment this runs in are worth knowing before
 * reading further, because they explain most of the shape of this file.
 *
 * 1. There is no module system. pvemanagerlib.js is one concatenated bundle in
 *    one global scope, and so is everything loaded beside it. `Proxmod` is our
 *    entire namespace, and an extension that creates a second global is
 *    squatting on a name it does not own.
 *
 * 2. The global `Proxmox` (no d) already exists and belongs to Proxmox — it is
 *    created inline in index.html.tpl and carries the CSRF token. The one-letter
 *    difference is unfortunate and permanent. Never assign to it.
 *
 * 3. This file is served to anyone who can reach port 8006, before they have
 *    logged in [PVE-F-023]. It contains no secrets, and neither may any
 *    extension asset.
 *
 * The prime directive applies here as much as in the Perl: a broken extension
 * must cost its own tab, not the web interface. Every callback into extension
 * code is wrapped, and every failure becomes a console message and nothing
 * more.
 */

/* global Ext, Proxmox, gettext */

var Proxmod = Proxmod || {};

(function () {
    'use strict';

    if (Proxmod.ui) {
        // The loader is idempotent and the index carries exactly one script
        // tag, so arriving here twice means something else is loading us.
        return;
    }

    Proxmod.version = '0.1.0';

    // ----------------------------------------------------------------- log

    // Extensions fail silently by design; this is where the evidence goes.
    // Prefixed so a support request that includes a console dump is
    // immediately attributable.
    function report(level, message, err) {
        if (typeof console === 'undefined' || !console[level]) {
            return;
        }
        if (err) {
            console[level]('proxmod: ' + message, err);
        } else {
            console[level]('proxmod: ' + message);
        }
    }

    Proxmod.log = {
        debug: function (m) { report('log', m); },
        warn: function (m, e) { report('warn', m, e); },
        error: function (m, e) { report('error', m, e); },
    };

    // Run extension-supplied code so that it cannot take the caller with it.
    // Returns the value, or undefined if it threw.
    function guard(what, fn) {
        try {
            return fn();
        } catch (err) {
            Proxmod.log.error(what + ' failed', err);
            return undefined;
        }
    }

    Proxmod.guard = guard;

    // ----------------------------------------------------------------- api

    // proxmod's REST namespace is fixed: an extension answers below
    // /nodes/{node}/proxmod/<id> or /cluster/proxmod/<id> and nowhere else.
    // Building the URL here rather than in each extension is what makes that
    // true in practice as well as on paper.
    var SEGMENT = 'proxmod';

    function joinPath(base, path) {
        if (!path) {
            return base;
        }
        return base + '/' + String(path).replace(/^\/+/, '');
    }

    Proxmod.api = {
        // The bare API path, as Proxmox.Utils.API2Request wants it: that helper
        // prepends /api2/extjs itself.
        url: function (ext, path, node) {
            if (node) {
                return joinPath('/nodes/' + node + '/' + SEGMENT + '/' + ext, path);
            }
            return joinPath('/cluster/' + SEGMENT + '/' + ext, path);
        },

        // The absolute URL, for the places that want one — Proxmox.data.ObjectStore
        // and Ext.data.Store both take a full /api2/json path.
        storeUrl: function (ext, path, node) {
            return '/api2/json' + Proxmod.api.url(ext, path, node);
        },

        request: function (opts) {
            var o = opts || {};
            if (!o.ext) {
                Proxmod.log.error('api.request called without an extension id');
                return;
            }
            var params = Ext.apply({}, o.params);
            // {node} is a declared parameter of every node-scoped method, and
            // PVE validates it against the path. Sending it explicitly means an
            // extension never has to remember to.
            if (o.node && params.node === undefined) {
                params.node = o.node;
            }
            Proxmox.Utils.API2Request({
                url: Proxmod.api.url(o.ext, o.path, o.node),
                method: o.method || 'GET',
                params: params,
                waitMsgTarget: o.waitMsgTarget,
                success: o.success,
                failure: o.failure || function (response) {
                    Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                },
            });
        },
    };

    ['GET', 'POST', 'PUT', 'DELETE'].forEach(function (method) {
        Proxmod.api[method.toLowerCase()] = function (ext, path, opts) {
            var o = Ext.apply({}, opts);
            o.ext = ext;
            o.path = path;
            o.method = method;
            Proxmod.api.request(o);
        };
    });

    // ------------------------------------------------------------------ ui

    // The classes an extension may hang a tab on, and what each one is called
    // in a request. Every one of these is a PVE.panel.Config subclass, which is
    // the only reason the insertNodes() trick below works [PVE-F-030].
    var TARGETS = {
        node: 'PVE.node.Config',
        qemu: 'PVE.qemu.Config',
        lxc: 'PVE.lxc.Config',
        datacenter: 'PVE.dc.Config',
    };

    // One entry per target: the tabs registered for it, and whether the
    // override has been installed. There is exactly ONE override per class no
    // matter how many extensions register — a chain of N overrides is N chances
    // for one extension's callParent to swallow another's.
    var registry = {};

    Object.keys(TARGETS).forEach(function (key) {
        registry[key] = { tabs: [], installed: false };
    });

    // insertNodes throws 'itemId already exists' on a duplicate [PVE-F-032],
    // and it throws it from inside initComponent — which would blank the panel.
    // Every itemId is therefore prefixed with the extension id, and checked
    // against savedItems before we hand it over.
    function itemIdFor(spec) {
        if (spec.itemId) {
            return String(spec.itemId);
        }
        return 'proxmod-' + spec.ext + (spec.id ? '-' + spec.id : '');
    }

    // Turn a registration into the item insertNodes wants. Rebuilt per panel
    // instance, deliberately: insertNodes mutates what it is given — it shifts
    // `groups` empty and sets `header` — so a shared object works once and then
    // silently misplaces the tab on every panel after the first.
    function buildItem(spec, panel, nodename) {
        var item = Ext.apply({}, spec.item);

        item.itemId = itemIdFor(spec);
        item.title = spec.title || item.title || spec.ext;
        if (spec.iconCls || item.iconCls) {
            item.iconCls = spec.iconCls || item.iconCls;
        }
        if (spec.groups) {
            item.groups = spec.groups.slice();
        }

        item.pveSelNode = panel.pveSelNode;
        if (nodename && item.nodename === undefined) {
            item.nodename = nodename;
        }

        return item;
    }

    // Best-effort ordering. insertNodes always appends, so a tab asking to sit
    // after an existing one is moved afterwards. If anything about the tree is
    // not as expected the tab simply stays where it landed — a tab in the wrong
    // place is a cosmetic problem, and not worth a thrown exception during
    // initComponent.
    function placeAfter(panel, itemId, afterId) {
        var root = panel.store && panel.store.getRoot();
        if (!root) {
            return;
        }
        var ours = root.findChild('id', itemId, true);
        var anchor = root.findChild('id', afterId, true);
        if (!ours || !anchor || ours.parentNode !== anchor.parentNode) {
            return;
        }
        anchor.parentNode.insertBefore(ours, anchor.nextSibling);
    }

    function applyTabs(key, panel) {
        var entry = registry[key];
        var nodename = panel.pveSelNode && panel.pveSelNode.data
            ? panel.pveSelNode.data.node
            : undefined;

        entry.tabs.forEach(function (spec) {
            guard('tab ' + spec.ext + '/' + itemIdFor(spec), function () {
                var item = buildItem(spec, panel, nodename);

                // Cheaper and quieter than letting insertNodes throw. A
                // collision is a packaging bug in one extension; it must not
                // stop the tabs registered after it.
                if (panel.savedItems && panel.savedItems[item.itemId] !== undefined) {
                    Proxmod.log.warn('tab itemId "' + item.itemId
                        + '" already exists on ' + TARGETS[key] + ', skipping it');
                    return;
                }

                panel.insertNodes([item]);

                if (spec.after) {
                    guard('placing tab ' + item.itemId, function () {
                        placeAfter(panel, item.itemId, spec.after);
                    });
                }
            });
        });
    }

    function install(key) {
        var entry = registry[key];
        if (entry.installed) {
            return true;
        }

        var target = TARGETS[key];

        // The seam probe. Defining an override for a class that does not exist
        // leaves it pending in Ext.Loader forever; refusing here means an
        // extension written for a PVE that renamed the class degrades to no tab
        // instead of to a stuck UI.
        if (!Ext.ClassManager || !Ext.ClassManager.get(target)) {
            Proxmod.log.warn('cannot add tabs to ' + target
                + ': the class does not exist in this Proxmox VE');
            return false;
        }

        Ext.define('Proxmod.override.' + key, {
            override: target,

            initComponent: function () {
                var me = this;

                // callParent FIRST. PVE.panel.Config.initComponent consumes
                // me.items, deletes it, and builds the tree store; only after
                // that has run does insertNodes exist to be called
                // [PVE-F-031]. Pushing onto me.items before callParent works
                // too, but only for the top level, and it breaks the moment a
                // tab wants a group.
                me.callParent(arguments);

                guard('adding tabs to ' + target, function () {
                    applyTabs(key, me);
                });
            },
        });

        entry.installed = true;
        return true;
    }

    // spec: { ext, id, title, iconCls, xtype (or item), groups, after }
    function addTab(key, spec) {
        if (!registry[key]) {
            Proxmod.log.error('unknown tab target "' + key + '"');
            return false;
        }
        if (!spec || !spec.ext) {
            Proxmod.log.error('addTab needs the registering extension id in "ext"');
            return false;
        }
        if (!spec.xtype && !(spec.item && spec.item.xtype)) {
            Proxmod.log.error(spec.ext + ': addTab needs an xtype');
            return false;
        }

        var entry = {
            ext: String(spec.ext),
            id: spec.id,
            itemId: spec.itemId,
            title: spec.title,
            iconCls: spec.iconCls,
            groups: spec.groups,
            after: spec.after,
            item: Ext.apply({}, spec.item),
        };
        if (spec.xtype) {
            entry.item.xtype = spec.xtype;
        }

        if (!install(key)) {
            return false;
        }

        registry[key].tabs.push(entry);
        return true;
    }

    Proxmod.ui = {
        targets: TARGETS,
        addTab: addTab,
        addNodeTab: function (spec) { return addTab('node', spec); },
        addQemuTab: function (spec) { return addTab('qemu', spec); },
        addLxcTab: function (spec) { return addTab('lxc', spec); },
        addDatacenterTab: function (spec) { return addTab('datacenter', spec); },

        // Both guest types at once, which is what "add a tab to every VM" means
        // in practice and what everyone gets wrong on the first attempt.
        addGuestTab: function (spec) {
            var q = addTab('qemu', spec);
            var l = addTab('lxc', spec);
            return q && l;
        },

        // Read-only view of what has been registered. proxmod-verify and the
        // browser console both use it; nothing else should.
        registrations: function () {
            var out = [];
            Object.keys(registry).forEach(function (key) {
                registry[key].tabs.forEach(function (tab) {
                    out.push({ target: key, ext: tab.ext, itemId: itemIdFor(tab) });
                });
            });
            return out;
        },
    };

    // --------------------------------------------------------------- style

    // An extension that needs CSS gets one <style> element, keyed by its id, so
    // that reloading an asset cannot accumulate duplicates.
    Proxmod.ui.addStyle = function (ext, css) {
        var id = 'proxmod-style-' + ext;
        var el = document.getElementById(id);
        if (!el) {
            el = document.createElement('style');
            el.id = id;
            el.type = 'text/css';
            document.getElementsByTagName('head')[0].appendChild(el);
        }
        el.textContent = css;
    };
}());
