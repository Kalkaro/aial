const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const search = vm.createContext({});
const source = fs.readFileSync(path.join(__dirname, "../rofi-search.js"), "utf8");
vm.runInContext(source.replace(/^\.pragma library\s*/, ""), search);

function matches(query, entries, options) {
    const apps = entries.map(entry => search.prepareApplication(entry));
    return Array.from(search.search(query, apps, options), entry => entry.name);
}

const applications = [
    { id: "spotify.desktop", name: "Spotify", genericName: "Music Player", execString: "spotify", keywords: ["Music"] },
    { id: "discord.desktop", name: "Discord", execString: "discord", categories: ["Chat"] },
    { id: "firefox.desktop", name: "Firefox", execString: "firefox" }
];

test("English app names typed using the Russian layout match", () => {
    assert.deepEqual(matches("ызщешан", applications), ["Spotify"]);
    assert.deepEqual(matches("вшысщкв", applications), ["Discord"]);
    assert.deepEqual(matches("ашкуащч", applications), ["Firefox"]);
});

test("partial, uppercase, and mixed-layout input matches", () => {
    assert.deepEqual(matches("ызщ", applications), ["Spotify"]);
    assert.deepEqual(matches("ВШЫ", applications), ["Discord"]);
    assert.deepEqual(matches("sзщешан", applications), ["Spotify"]);
    assert.deepEqual(matches("  ызщешан  ", applications), ["Spotify"]);
    assert.deepEqual(matches(".ые", [{ name: "example.st" }]), ["example.st"]);
});

test("original Cyrillic matches are retained alongside layout matches", () => {
    const entries = [
        { name: "Music" },
        { name: "ьгышс" },
        { name: "Музыка" },
        { name: "Spotify ызщешан" }
    ];
    assert.deepEqual(matches("ьгышс", entries).sort(), ["Music", "ьгышс"]);
    assert.deepEqual(matches("музыка", entries), ["Музыка"]);
    assert.deepEqual(matches("ызщешан", entries), ["Spotify ызщешан"]);
});

test("each token can match its original text or the English layout", () => {
    assert.deepEqual(matches("Spotify ьгышс", applications), ["Spotify"]);
    assert.deepEqual(matches("ызщешан music", applications), ["Spotify"]);
    assert.deepEqual(matches("ызщешан музыка", [
        { name: "Spotify", genericName: "Музыка" },
        { name: "Spotify", genericName: "Chat" }
    ]), ["Spotify"]);
    assert.deepEqual(matches("ызщешан среф", applications), []);
});

test("layout matching honors searchable fields and their ranking", () => {
    const entries = [
        { name: "Helper", execString: "spotify" },
        { name: "Spotify" },
        { name: "Player", keywords: ["Spotify"] }
    ];
    assert.deepEqual(matches("ызщешан", entries), ["Spotify", "Player", "Helper"]);
    assert.deepEqual(matches("ызщешан", entries, { matchFieldsSpec: "name" }), ["Spotify"]);
    assert.deepEqual(matches("ьгышс", applications), ["Spotify"]);
    assert.deepEqual(matches("срфе", applications), ["Discord"]);
});

test("negated tokens exclude both original and remapped text", () => {
    assert.deepEqual(matches("-вшысщкв", applications), ["Firefox", "Spotify"]);
    assert.deepEqual(matches("-вшысщкв", [
        { name: "вшысщкв" },
        { name: "Discord" },
        { name: "Firefox" }
    ]), ["Firefox"]);
    assert.deepEqual(matches("ызщешан -ьгышс", applications), []);
});

test("layout matching works with all matching methods", () => {
    for (const matchingMethod of ["normal", "prefix", "fuzzy", "glob", "regex"]) {
        assert.deepEqual(matches("ызщешан", applications, { matchingMethod }), ["Spotify"]);
    }
    assert.deepEqual(matches("ызщ*", applications, { matchingMethod: "glob" }), ["Spotify"]);
    assert.deepEqual(matches("^ызщ", applications, { matchingMethod: "regex" }), ["Spotify"]);
});

test("case-sensitive searches retain the case of remapped input", () => {
    assert.deepEqual(matches("Ызщешан", applications, { caseSensitive: true }), ["Spotify"]);
    assert.deepEqual(matches("ызщешан", applications, { caseSensitive: true, matchFieldsSpec: "name" }), []);
});

test("Cyrillic letter keys producing punctuation match literal punctuation", () => {
    const entries = [{ name: "[x];'.,`" }, { name: "{X}:\"<>~" }];
    assert.deepEqual(matches("хчъжэюбё", entries, { caseSensitive: true }), ["[x];'.,`"]);
    assert.deepEqual(matches("ХЧЪЖЭБЮЁ", entries, { caseSensitive: true }), ["{X}:\"<>~"]);
});

test("distance sorting uses the corrected query", () => {
    const entries = [
        { name: "Music", execString: "spotify" },
        { name: "A Spotify" },
        { name: "Spotify" }
    ];
    for (const sortingMethod of ["normal", "fzf"]) {
        const options = { sort: true, sortingMethod };
        assert.deepEqual(matches("ызщешан", entries, options), matches("spotify", entries, options));
        assert.equal(matches("ызщешан", entries, options)[0], "Spotify");
    }
});

test("layout matches preserve history ordering", () => {
    const entries = [
        { id: "spotify.desktop", name: "Spotify" },
        { id: "spotify-premium.desktop", name: "Spotify Premium" }
    ];
    const options = { drunHistory: { "spotify-premium.desktop": 2, "spotify.desktop": 1 } };
    assert.deepEqual(matches("ызщ", entries, options), ["Spotify Premium", "Spotify"]);
});

test("English, empty, and unsupported-script searches keep working", () => {
    assert.deepEqual(matches("spotify", applications), ["Spotify"]);
    assert.deepEqual(matches("discord", applications), ["Discord"]);
    assert.deepEqual(matches("", applications), []);
    assert.deepEqual(matches("   ", applications), []);
    assert.deepEqual(matches("無関係", applications), []);
    assert.deepEqual(matches("東京", [{ name: "東京" }]), ["東京"]);
});
