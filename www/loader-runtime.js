/*
 * loader-runtime.js — the body of /proxmod/loader.js.
 *
 * This file is NOT served to browsers. Proxmod::Frontend reads it from
 * /usr/share/proxmod/loader-runtime.js, replaces the assets placeholder below
 * with a JSON array built from the live extension registry, and serves the
 * result as /proxmod/loader.js. Keeping it as a real .js file rather than a
 * heredoc in the Perl means it can be linted and read as JavaScript.
 *
 * The placeholder is a quoted string so that the file on disk is valid
 * JavaScript on its own; after substitution the same position holds an array.
 * It must appear exactly once in this file, quotes included — Frontend refuses
 * to generate a loader otherwise, because substituting a mention of it in a
 * comment would produce a loader that silently loads nothing.
 *
 * Why generate the list per request instead of writing a static file at install
 * time: a frontend-only extension then needs no daemon restart at all. Install
 * the .deb, reload the browser, and the tab is there.
 *
 * Ordering is the whole job. Extension code calls Ext.define({override: ...})
 * against PVE classes, so every asset must execute:
 *
 *   - after pvemanagerlib.js, or the class being overridden does not exist yet
 *   - before the inline Ext.onReady in index.html, or PVE.StdWorkspace has
 *     already been built and the first panel may already be constructed
 *   - in registry order, so an extension that requires another sees it
 *
 * The script tag for this file sits between those two [PVE-F-021], and
 * document.write from a parser-blocking script inserts the assets at exactly
 * this point in the document — which is the only mechanism that satisfies all
 * three without a module loader.
 */

/* global Proxmod */

(function () {
    'use strict';

    var assets = "__PROXMOD_ASSETS__";

    function note(level, message) {
        if (typeof console !== 'undefined' && console[level]) {
            console[level]('proxmod: ' + message);
        }
    }

    if (!assets || !assets.length) {
        return;
    }

    // The parser is blocked on this script, so document.write() inserts the
    // tags right here and the browser runs them in order before it reaches the
    // inline Ext.onReady below. This is the intended path and the only one that
    // preserves ordering relative to code already in the page.
    if (document.readyState === 'loading') {
        var html = '';
        for (var i = 0; i < assets.length; i++) {
            // Every url in the list was built by Proxmod::Frontend from a name
            // matching /^[A-Za-z0-9][A-Za-z0-9._-]*\.js$/, so it cannot contain
            // a quote or an angle bracket. The check is repeated in the Perl;
            // this comment is here so nobody relaxes one of the two in the
            // belief that the other is doing the work.
            html += '<script type="text/javascript" src="'
                + assets[i].url + '"><\/script>';
        }
        document.write(html);
        return;
    }

    // Fallback: something loaded us after parsing finished. async=false keeps
    // the assets in order relative to each other, but they will now run after
    // Ext.onReady, so an extension that adds a tab may miss the panel that is
    // already on screen. Say so rather than leaving someone to wonder why the
    // tab appears only after a navigation.
    note('warn', 'loaded after the document was parsed; extension assets will'
        + ' run late and may not appear until you navigate');

    var head = document.getElementsByTagName('head')[0] || document.documentElement;
    assets.forEach(function (asset) {
        var el = document.createElement('script');
        el.type = 'text/javascript';
        el.async = false;
        el.src = asset.url;
        el.onerror = function () {
            note('error', 'extension asset failed to load: ' + asset.url);
        };
        head.appendChild(el);
    });
}());
