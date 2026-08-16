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

    // The classes an extension may hang a tab or a menu item on, and what each
    // one is called in a request. Every one of these is a PVE.panel.Config
    // subclass, which is the only reason the insertNodes() trick below works
    // [PVE-F-030]. The list mirrors the resource tree's own type-to-class map
    // [PVE-F-034] minus 'tag', which has no per-object configuration panel.
    var TARGETS = {
        datacenter: 'PVE.dc.Config',
        node: 'PVE.node.Config',
        qemu: 'PVE.qemu.Config',
        lxc: 'PVE.lxc.Config',
        storage: 'PVE.storage.Browser',
        pool: 'PVE.pool.Config',
        zone: 'PVE.sdn.Browser',
        network: 'PVE.network.Browser',
    };

    // Names for sets of targets. 'guest' is here because "add this to every VM"
    // is what people mean and forgetting the container half is what they
    // actually ship.
    var TARGET_SETS = {
        guest: ['qemu', 'lxc'],
        all: Object.keys(TARGETS),
    };

    // What a card needs to know about the object it is showing. PVE keeps these
    // on the selected resource-tree node and copies them onto each child item by
    // hand; the names on the right are the ones its own panels use, so an
    // extension card can be written exactly like a stock one [PVE-F-034]. Note
    // the rename: the tree calls a zone 'sdn' and every panel calls it 'zone'.
    var CONTEXT = {
        node: 'nodename',
        vmid: 'vmid',
        storage: 'storage',
        pool: 'pool',
        sdn: 'zone',
        'zone-type': 'zoneType',
    };

    // One entry per target: the tabs and menu items registered for it, the
    // per-root menu configuration, and whether the override has been installed.
    // There is exactly ONE override per class no matter how many extensions
    // register — a chain of N overrides is N chances for one extension's
    // callParent to swallow another's.
    var registry = {};

    Object.keys(TARGETS).forEach(function (key) {
        registry[key] = { tabs: [], menu: [], menuConfig: {}, installed: false };
    });

    function contextFor(panel) {
        var data = (panel.pveSelNode && panel.pveSelNode.data) || {};
        var ctx = {};
        Object.keys(CONTEXT).forEach(function (from) {
            var v = data[from];
            if (v !== undefined && v !== null && v !== '') {
                ctx[CONTEXT[from]] = v;
            }
        });
        return ctx;
    }

    // Resolve a spec's target list. Returns [] rather than throwing on an
    // unknown name: one typo should cost one target, not the registration.
    function resolveTargets(spec, fallback) {
        var raw = spec.targets || spec.target || fallback;
        if (!raw) {
            return [];
        }
        var out = [];
        var bad = [];
        (Ext.isArray(raw) ? raw : [raw]).forEach(function (name) {
            (TARGET_SETS[name] || [name]).forEach(function (key) {
                if (!registry[key]) {
                    if (bad.indexOf(key) < 0) { bad.push(key); }
                } else if (out.indexOf(key) < 0) {
                    out.push(key);
                }
            });
        });
        if (bad.length) {
            Proxmod.log.error('unknown target(s): ' + bad.join(', ')
                + '; known targets are ' + Object.keys(TARGETS).join(', '));
        }
        return out;
    }

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
    function buildItem(spec, panel, ctx) {
        var item = Ext.apply({}, spec.item);

        item.itemId = itemIdFor(spec);
        item.title = spec.title || item.title || spec.ext;
        if (spec.iconCls || item.iconCls) {
            item.iconCls = spec.iconCls || item.iconCls;
        }
        if (spec.groups) {
            item.groups = spec.groups.slice();
        }

        // What the card is being shown for. An extension card can then be
        // written exactly like a stock PVE one — read this.nodename, this.vmid,
        // this.storage — rather than digging through pveSelNode itself.
        item.pveSelNode = panel.pveSelNode;
        Object.keys(ctx || {}).forEach(function (name) {
            if (item[name] === undefined) {
                item[name] = ctx[name];
            }
        });

        return item;
    }

    // Cheaper and quieter than letting insertNodes throw. A collision is a
    // packaging bug in one extension; it must not stop what was registered
    // after it, and it must not blank the panel it happens on.
    function insertNode(key, panel, item) {
        if (panel.savedItems && panel.savedItems[item.itemId] !== undefined) {
            Proxmod.log.warn('itemId "' + item.itemId + '" already exists on '
                + TARGETS[key] + ', skipping it');
            return false;
        }
        panel.insertNodes([item]);
        return true;
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

    function applyTabs(key, panel, ctx) {
        registry[key].tabs.forEach(function (spec) {
            guard('tab ' + spec.ext + '/' + itemIdFor(spec), function () {
                var item = buildItem(spec, panel, ctx);
                if (!insertNode(key, panel, item)) {
                    return;
                }
                if (spec.after) {
                    guard('placing tab ' + item.itemId, function () {
                        placeAfter(panel, item.itemId, spec.after);
                    });
                }
            });
        });
    }

    // ------------------------------------------------------------ menu items

    // The config panel's left-hand menu is that same treelist, and two of its
    // properties decide the whole design below [PVE-F-033]:
    //
    //   * insertNodes always appendChild()s, so anything added after callParent
    //     lands at the BOTTOM of the menu — which is where these belong;
    //   * `groups` are DESCENDED INTO, never created. A group is nothing more
    //     than an earlier item whose itemId matches, and it keeps a card of its
    //     own in savedItems.
    //
    // So "a parent with its own screen and children underneath" is the native
    // shape here rather than a workaround — PVE builds its own Services group
    // on the node panel exactly this way. The rule that follows is a
    // correctness requirement, not a preference: the parent must be inserted
    // BEFORE any child naming it, or insertNodes quietly drops the child at the
    // top level and the extension's screens scatter through the menu.
    var MENU_ROOT = 'proxmod';
    var MENU_ROOT_XTYPE = 'proxmodMenuRoot';

    // Registration order, used only to break weight ties. A menu whose contents
    // shuffle between page loads is its own bug report.
    var menuSeq = 0;
    var menuRootDefined = false;

    // The parent item's card. It is a plain panel either way: 'tabs' puts one
    // tabpanel inside it rather than extending Ext.tab.Panel, so there is one
    // class to reason about and the layout stays a runtime choice.
    function defineMenuRoot() {
        if (menuRootDefined) {
            return;
        }
        menuRootDefined = true;

        Ext.define('Proxmod.panel.MenuRoot', {
            extend: 'Ext.panel.Panel',
            alias: 'widget.' + MENU_ROOT_XTYPE,

            border: 0,
            scrollable: true,

            // Set by installRoot. None of this is a PVE contract.
            proxmodSections: null,
            proxmodScreens: null,
            proxmodLayout: 'stacked',
            proxmodContext: null,

            initComponent: function () {
                var me = this;
                var items = [];

                (me.proxmodSections || []).forEach(function (spec) {
                    var card = guard('menu section ' + spec.ext + '/' + itemIdFor(spec),
                        function () { return me.proxmodSection(spec); });
                    if (card) {
                        items.push(card);
                    }
                });

                if (!items.length) {
                    // activateCard add()s whatever savedItems holds, so a card
                    // with nothing in it is a blank pane rather than an error —
                    // and a blank pane is worse than a sentence.
                    items = [me.proxmodPlaceholder()];
                    me.layout = 'fit';
                } else if (me.proxmodLayout === 'tabs') {
                    items = [{ xtype: 'tabpanel', border: 0, items: items }];
                    me.layout = 'fit';
                    me.scrollable = false;
                } else {
                    me.layout = 'anchor';
                    me.defaults = Ext.apply({ anchor: '100%' }, me.defaults);
                }

                me.items = items;
                me.callParent();
            },

            proxmodSection: function (spec) {
                var me = this;
                var card = Ext.apply({}, spec.item);

                card.itemId = itemIdFor(spec);
                card.title = spec.title || card.title || spec.ext;
                if (spec.iconCls || card.iconCls) {
                    card.iconCls = spec.iconCls || card.iconCls;
                }

                card.pveSelNode = me.pveSelNode;
                Object.keys(me.proxmodContext || {}).forEach(function (name) {
                    if (card[name] === undefined) {
                        card[name] = me.proxmodContext[name];
                    }
                });

                // Stacked sections are titled boxes down one scrolling column,
                // the same visual language as the Summary page; tabs are pages
                // and the tabpanel already frames them.
                if (me.proxmodLayout !== 'tabs' && card.margin === undefined) {
                    card.margin = '0 0 10 0';
                }

                return card;
            },

            proxmodPlaceholder: function () {
                var names = (this.proxmodScreens || []).map(function (spec) {
                    return Ext.String.htmlEncode(spec.title || spec.ext);
                });
                var text = names.length
                    ? gettext('Select an item below.') + ' (' + names.join(', ') + ')'
                    : gettext('No extension has registered anything here.');
                return {
                    xtype: 'panel',
                    border: 0,
                    bodyPadding: 20,
                    html: '<p>' + text + '</p>',
                };
            },
        });
    }

    // One root per parent node: the shared 'proxmod' item, plus one per
    // extension that asked to stand alone.
    function rootsFor(key) {
        var roots = [];
        var byId = {};

        registry[key].menu.slice().sort(function (a, b) {
            return (a.weight - b.weight) || (a.seq - b.seq);
        }).forEach(function (spec) {
            var id = spec.standalone ? 'proxmod-' + spec.ext : MENU_ROOT;
            if (!byId[id]) {
                byId[id] = {
                    id: id,
                    ext: spec.ext,
                    standalone: spec.standalone,
                    sections: [],
                    screens: [],
                };
                roots.push(byId[id]);
            }
            byId[id][spec.mode === 'section' ? 'sections' : 'screens'].push(spec);
        });

        return roots;
    }

    function installRoot(key, panel, root, ctx) {
        var cfg = registry[key].menuConfig[root.id] || {};

        // One extension, one screen, no sections: a parent wrapping a single
        // child is noise, and "give my extension its own menu entry" is what
        // standalone was asked for. So the screen IS the top-level item.
        if (root.standalone && !root.sections.length && root.screens.length === 1) {
            insertNode(key, panel, buildItem(root.screens[0], panel, ctx));
            return;
        }

        var item = buildItem({
            ext: root.ext,
            itemId: root.id,
            title: cfg.title || (root.standalone ? root.ext : 'Proxmod'),
            iconCls: cfg.iconCls || 'fa fa-puzzle-piece',
            item: {
                xtype: MENU_ROOT_XTYPE,
                expandedOnInit: cfg.expandedOnInit === undefined
                    ? true
                    : !!cfg.expandedOnInit,
                proxmodSections: root.sections,
                proxmodScreens: root.screens,
                proxmodLayout: cfg.layout === 'tabs' ? 'tabs' : 'stacked',
                proxmodContext: ctx,
            },
        }, panel, ctx);

        // If the parent did not go in, the children must not either: with no
        // group to descend into they would land at the top level.
        if (!insertNode(key, panel, item)) {
            return;
        }

        root.screens.forEach(function (spec) {
            guard('menu screen ' + spec.ext + '/' + itemIdFor(spec), function () {
                var child = buildItem(spec, panel, ctx);
                child.groups = [root.id];

                // A standalone extension that registered a screen without an id
                // would otherwise collide with the parent built from the same id.
                if (child.itemId === root.id) {
                    child.itemId = root.id + '-screen';
                }

                if (insertNode(key, panel, child) && spec.after) {
                    guard('placing menu item ' + child.itemId, function () {
                        placeAfter(panel, child.itemId, spec.after);
                    });
                }
            });
        });
    }

    function applyMenu(key, panel, ctx) {
        rootsFor(key).forEach(function (root) {
            guard('menu item ' + root.id + ' on ' + TARGETS[key], function () {
                installRoot(key, panel, root, ctx);
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
            Proxmod.log.warn('cannot extend ' + target
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

                guard('adding proxmod items to ' + target, function () {
                    var ctx = contextFor(me);
                    applyTabs(key, me, ctx);
                    applyMenu(key, me, ctx);
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

    // spec: { ext, targets|target, mode, id, itemId, title, iconCls,
    //         xtype (or item), standalone, weight, after }
    function addMenuItem(spec) {
        var o = spec || {};

        if (!o.ext) {
            Proxmod.log.error('addMenuItem needs the registering extension id in "ext"');
            return false;
        }
        if (!o.xtype && !(o.item && o.item.xtype)) {
            Proxmod.log.error(o.ext + ': addMenuItem needs an xtype');
            return false;
        }

        var keys = resolveTargets(o);
        if (!keys.length) {
            Proxmod.log.error(o.ext + ': addMenuItem needs at least one target');
            return false;
        }

        defineMenuRoot();

        var ok = true;
        keys.forEach(function (key) {
            if (!install(key)) {
                ok = false;
                return;
            }
            var entry = {
                ext: String(o.ext),
                id: o.id,
                itemId: o.itemId === undefined ? undefined : String(o.itemId),
                title: o.title,
                iconCls: o.iconCls,
                after: o.after,
                mode: o.mode === 'section' ? 'section' : 'screen',
                standalone: !!o.standalone,
                weight: o.weight === undefined ? 50 : Number(o.weight),
                seq: menuSeq++,
                item: Ext.apply({}, o.item),
            };
            if (o.xtype) {
                entry.item.xtype = o.xtype;
            }
            registry[key].menu.push(entry);
        });

        return ok;
    }

    // spec: { targets|target, ext, title, iconCls, layout, expandedOnInit }
    // With no `ext` this configures the shared Proxmod parent; with one, that
    // extension's standalone parent. Defaults to every target, because a parent
    // that looks different depending on what you clicked is a bug.
    function configureMenu(spec) {
        var o = spec || {};
        var id = o.ext ? 'proxmod-' + o.ext : MENU_ROOT;

        resolveTargets(o, 'all').forEach(function (key) {
            var cfg = registry[key].menuConfig[id] || {};
            // One key at a time, so leaving a field out of a later call does
            // not silently unset what an earlier one asked for.
            ['title', 'iconCls', 'layout', 'expandedOnInit'].forEach(function (name) {
                if (o[name] !== undefined) {
                    cfg[name] = o[name];
                }
            });
            registry[key].menuConfig[id] = cfg;
        });

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

        // A menu item lives in the config panel's left-hand tree rather than in
        // its tab bar. A screen is a node of its own under the parent, with its
        // own card; a section is rendered in the parent's own card.
        addMenuItem: addMenuItem,
        addMenuScreen: function (spec) {
            var o = Ext.apply({}, spec);
            o.mode = 'screen';
            return addMenuItem(o);
        },
        addMenuSection: function (spec) {
            var o = Ext.apply({}, spec);
            o.mode = 'section';
            return addMenuItem(o);
        },
        configureMenu: configureMenu,

        // Read-only view of what has been registered. proxmod-verify and the
        // browser console both use it; nothing else should.
        registrations: function () {
            var out = [];
            Object.keys(registry).forEach(function (key) {
                registry[key].tabs.forEach(function (tab) {
                    out.push({
                        target: key,
                        kind: 'tab',
                        ext: tab.ext,
                        itemId: itemIdFor(tab),
                    });
                });
                registry[key].menu.forEach(function (menu) {
                    out.push({
                        target: key,
                        kind: 'menu-' + menu.mode,
                        ext: menu.ext,
                        itemId: itemIdFor(menu),
                        parent: menu.standalone ? 'proxmod-' + menu.ext : MENU_ROOT,
                    });
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
