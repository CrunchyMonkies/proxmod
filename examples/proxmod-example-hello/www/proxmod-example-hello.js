// proxmod hello example — the frontend half.
//
// Served from /proxmod/proxmod-example-hello.js and loaded by proxmod's loader
// after pvemanagerlib.js, so every PVE.* class exists and the translations are
// loaded, but no Ext.onReady handler has run yet [PVE-F-021]. That window is
// what makes it possible to override a component that has not been constructed.
//
// Three things to know before writing one of these:
//
//   1. There is no module loader. The Proxmox web interface is one concatenated
//      bundle in a single global scope, so everything below is wrapped in an
//      IIFE and touches exactly one global: its own class name.
//   2. This file is served WITHOUT AUTHENTICATION [PVE-F-023]. Anyone who can
//      reach port 8006 can read it. No hostnames, no tokens, no internal paths.
//   3. A thrown exception here can blank the entire interface. proxmod calls
//      into extensions inside a try/catch and the helpers below are written to
//      degrade into a missing tab, but that protection stops at the boundary —
//      code inside a component's own callbacks is on its own.

(function () {
    'use strict';

    // proxmod may not be present: an administrator can disable it, and this
    // file could be loaded by something else entirely. Fail into doing nothing.
    if (typeof Proxmod === 'undefined' || !Proxmod.ui) {
        return;
    }

    Ext.define('ProxmodExample.HelloPanel', {
        extend: 'Ext.panel.Panel',
        alias: 'widget.proxmodExampleHello',

        title: gettext('Hello'),
        border: false,
        padding: 10,

        // nodename is handed in by the tab host. Never read it out of the URL.
        nodename: undefined,

        initComponent: function () {
            var me = this;

            if (!me.nodename) {
                throw 'no node name specified';
            }

            me.items = [
                {
                    xtype: 'displayfield',
                    fieldLabel: gettext('Message'),
                    itemId: 'message',
                    value: '',
                },
                {
                    xtype: 'displayfield',
                    fieldLabel: gettext('Load average'),
                    itemId: 'loadavg',
                    value: '',
                },
            ];

            me.callParent();

            me.reload();
        },

        reload: function () {
            var me = this;

            // The URL is not ours to choose. Proxmod.api builds
            // /nodes/<node>/proxmod/example-hello/greet from the extension id,
            // which is the same rule the Perl half registers under.
            Proxmod.api.get('example-hello', 'greet', {
                node: me.nodename,
                waitMsgTarget: me,
                // Proxmox.Utils.API2Request hands the callback the whole
                // response, not the payload; what the method returned is under
                // result.data.
                success: function (response) {
                    var data = response.result.data;

                    // A displayfield renders its value as HTML. Both of these
                    // came back from an API call, so both go through
                    // Ext.String.htmlEncode — loadavg included, because "it is
                    // a number in the schema" is a statement about the server
                    // and this code is running in someone else's browser.
                    me.down('#message').setValue(Ext.String.htmlEncode(data.message));
                    me.down('#loadavg').setValue(Ext.String.htmlEncode('' + data.loadavg));
                },
                failure: function (response) {
                    me.down('#message').setValue(response.htmlStatus);
                },
            });
        },
    });

    // One call, one tab. addNodeTab maintains a single override chain per host
    // class no matter how many extensions add tabs, and swallows an exception
    // from this callback rather than letting it reach Ext's constructor.
    Proxmod.ui.addNodeTab({
        // The registering extension, and the only thing that decides the tab's
        // itemId: this becomes 'proxmod-example-hello'. Setting itemId by hand
        // is allowed and is how two extensions collide, so do not.
        ext: 'example-hello',
        title: gettext('Hello'),
        iconCls: 'fa fa-comment-o',
        xtype: 'proxmodExampleHello',
        // Where the tab lands among the node's existing ones. Expressed
        // relative to a PVE tab rather than as an index, because an index moves
        // every time Proxmox adds a tab of its own.
        after: 'system',
    });
})();
