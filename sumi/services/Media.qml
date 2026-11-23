pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Mpris

/**
 * The one now-playing source the shell reads.
 *
 * Two players are filtered out of the picker so the user never has to choose
 * between a program and its own backend:
 *   · `playerctld` is a proxy for whatever else is running, not a player;
 *   · anything paused with no title is idle — on this machine that is the bare
 *     `mpv` instance maly drives, which publishes an MPRIS name and a cover but
 *     no `xesam:title`.
 *
 * Selection: whatever you picked by hand while it lasts, else the one that is
 * actually playing, with the most recently started preferred. Pausing your
 * music therefore does not hand the card to a paused background tab, but
 * starting another player does switch to it.
 *
 * No network. Ukishima resolves Twitch avatars and Netflix titles by fetching
 * from decapi.me and netflix.com whenever the track URL changes; that leaks
 * what you are watching to a third party for a nicer thumbnail (ADR-7).
 */
Singleton {
    id: root

    function isProxy(p) {
        return (p && p.dbusName ? p.dbusName : "").toLowerCase().indexOf("playerctld") >= 0;
    }

    function hasTitle(p) {
        return p !== null && p.trackTitle !== undefined && p.trackTitle.length > 0;
    }

    /** Nothing to show: a proxy, or paused with no title. */
    function isIdle(p) {
        if (!p || root.isProxy(p))
            return true;
        return !p.isPlaying && !root.hasTitle(p);
    }

    readonly property var players: {
        const all = Mpris.players.values;
        const out = [];
        for (let i = 0; i < all.length; i++)
            if (all[i] && !root.isProxy(all[i]))
                out.push(all[i]);
        return out;
    }

    /**
     * Worth offering in a picker: awake, named, and not a duplicate of another
     * entry.
     *
     * The duplicate rule exists because of a real case on this machine: maly
     * plays through its own bare `mpv`, and both publish MPRIS with the SAME
     * title, artist and playing state. Nothing in the protocol says "I am the
     * backend of that other one", so two entries appear for one song. When two
     * players announce the same track at the same time, one of them is almost
     * always driving the other, and the earlier `uniqueId` is the program
     * rather than the backend it spawned.
     *
     * Known limit: two separate mpv windows on the same file collapse to one.
     * That is rarer than the backend case, and the picker still lets you reach
     * anything you selected by hand.
     */
    readonly property var pickable: {
        const seen = ({});
        const out = [];
        const l = root.players;
        for (let i = 0; i < l.length; i++) {
            const p = l[i];
            if (root.isIdle(p) || !root.hasTitle(p))
                continue;
            const key = p.trackTitle + "|" + (p.trackArtist || "");
            const prev = seen[key];
            if (prev === undefined) {
                seen[key] = p;
                out.push(p);
                continue;
            }
            // Keep whichever the user is actually on, else the older id.
            const better = (p === root.manual || p === root.preferred) ? p
                : ((prev === root.manual || prev === root.preferred) ? prev
                : (p.uniqueId < prev.uniqueId ? p : prev));
            if (better !== prev) {
                out[out.indexOf(prev)] = better;
                seen[key] = better;
            }
        }
        return out;
    }

    property var manual: null
    property var preferred: null

    onPlayersChanged: {
        if (root.manual && root.players.indexOf(root.manual) < 0)
            root.manual = null;
        if (root.preferred && root.players.indexOf(root.preferred) < 0)
            root.preferred = null;
    }

    function othersPlaying(self) {
        const l = root.players;
        for (let i = 0; i < l.length; i++)
            if (l[i] !== self && l[i].isPlaying)
                return true;
        return false;
    }

    readonly property var autoPick: {
        const l = root.players;
        if (l.length === 0)
            return null;
        if (root.preferred && l.indexOf(root.preferred) >= 0 && root.preferred.isPlaying
            && root.hasTitle(root.preferred))
            return root.preferred;
        // Prefer a playing entry the picker would also show, so a backend never
        // wins over the program driving it.
        const pick = root.pickable;
        for (let i = 0; i < pick.length; i++)
            if (pick[i].isPlaying)
                return pick[i];
        if (root.preferred && l.indexOf(root.preferred) >= 0 && !root.isIdle(root.preferred))
            return root.preferred;
        for (let j = 0; j < l.length; j++)
            if (!root.isIdle(l[j]))
                return l[j];
        return l[0];
    }

    readonly property var active: (root.manual && root.players.indexOf(root.manual) >= 0
        && !root.isIdle(root.manual)) ? root.manual : root.autoPick

    function select(p) {
        root.manual = (p && root.players.indexOf(p) >= 0) ? p : null;
    }

    /** Track the moment a player starts, so `preferred` follows what you just began. */
    property bool ready: false
    Component.onCompleted: root.ready = true

    Instantiator {
        model: Mpris.players
        delegate: QtObject {
            required property var modelData
            readonly property bool real: modelData && !Media.isProxy(modelData)
            readonly property bool playing: real ? modelData.isPlaying : false
            onPlayingChanged: {
                if (!Media.ready || !playing)
                    return;
                if (Media.hasTitle(modelData) && !Media.othersPlaying(modelData))
                    Media.preferred = modelData;
            }
        }
    }

    // ---- what the UI reads ---------------------------------------------

    readonly property bool has: root.active !== null
    readonly property bool playing: root.has && root.active.isPlaying
    readonly property string title: root.has && root.active.trackTitle ? root.active.trackTitle : ""
    readonly property string artist: root.has && root.active.trackArtist ? root.active.trackArtist : ""
    readonly property string album: root.has && root.active.trackAlbum ? root.active.trackAlbum : ""
    readonly property string sourceName: root.has
        ? (root.active.identity || root.active.desktopEntry || root.active.dbusName) : ""

    /** Cover art. `file:` urls get the track appended so a player that reuses one path still reloads. */
    readonly property string artUrl: {
        if (!root.has)
            return "";
        const u = root.active.trackArtUrl;
        if (!u || u.length === 0)
            return "";
        return u.indexOf("file:") === 0 ? u + "#" + root.trackKey : u;
    }
    readonly property string trackKey: root.has
        ? ((root.active.dbusName || "") + "|" + (root.active.trackTitle || "")) : ""

    readonly property real lengthSec: root.has && root.active.length > 0 ? root.active.length : 0
    readonly property real positionSec: root.has ? root.active.position : 0
    /** A near-INT64 length is how streams say "no end". */
    readonly property bool live: root.has && (root.lengthSec <= 0 || root.lengthSec > 86400)
    readonly property real progress: (!root.live && root.lengthSec > 0)
        ? Math.max(0, Math.min(1, root.positionSec / root.lengthSec)) : 0

    readonly property bool canToggle: root.has && root.active.canTogglePlaying
    readonly property bool canNext: root.has && root.active.canGoNext
    readonly property bool canPrev: root.has && root.active.canGoPrevious
    readonly property bool canSeek: root.has && root.active.canSeek
        && root.active.positionSupported && root.lengthSec > 0 && !root.live

    function toggle() { if (root.canToggle) root.active.togglePlaying(); return root.canToggle; }
    function next()   { if (root.canNext) root.active.next();          return root.canNext; }
    function previous() { if (root.canPrev) root.active.previous();    return root.canPrev; }
    function seekTo(frac) {
        if (!root.canSeek)
            return false;
        root.active.position = Math.max(0, Math.min(1, frac)) * root.lengthSec;
        return true;
    }

    /**
     * MPRIS does not push position updates, so anything showing progress has to
     * ask. Only while something is actually playing and a surface asked for it:
     * Whoever needs a moving bar claims it by name (fase 6A: era un contador).
     */
    property var claims: ({})
    readonly property int subscribers: Object.keys(root.claims).length
    function claim(who, on) {
        if (!!on === !!root.claims[who]) return;
        const c = Object.assign({}, root.claims);
        if (on) c[who] = true; else delete c[who];
        root.claims = c;
    }

    Timer {
        interval: 500
        repeat: true
        running: root.subscribers > 0 && root.playing && !root.live
        onTriggered: if (root.active) root.active.positionChanged()
    }
}
