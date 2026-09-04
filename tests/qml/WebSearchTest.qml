import Quickshell
import QtQuick
import qs.modules.launcher.services

ShellRoot {
    id: root

    property bool failed: false
    property var mockList: ({ screenState: { launcher: true } })

    function check(condition: bool, message: string): void {
        if (!condition) {
            failed = true;
            console.error(`WEBSEARCH_TEST_FAIL: ${message}`);
        }
    }

    Component.onCompleted: {
        const google = WebSearch.parse("google théorie de la relativité");
        check(google?.desc === "Google", "Google provider");
        check(google?.url === "https://www.google.com/search?q=th%C3%A9orie%20de%20la%20relativit%C3%A9", "Unicode encoding");

        const youtube = WebSearch.parse("  youtube   lofi   hip hop  ");
        check(youtube?.desc === "YouTube", "YouTube provider");
        check(youtube?.url === "https://www.youtube.com/results?search_query=lofi%20hip%20hop", "whitespace normalization");

        const special = WebSearch.parse("github C++ \"hello world\"");
        check(special?.url === "https://github.com/search?q=C%2B%2B%20%22hello%20world%22", "special-character encoding");

        const wiki = WebSearch.parse("wiki Alan Turing");
        check(wiki?.url === "https://fr.wikipedia.org/wiki/Special:Search?search=Alan%20Turing", "Wikipedia provider");
        const githubAlias = WebSearch.parse("gh caelestia");
        check(githubAlias?.url === "https://github.com/search?q=caelestia", "GitHub alias");
        const reddit = WebSearch.parse("reddit linux gaming");
        check(reddit?.url === "https://www.reddit.com/search/?q=linux%20gaming", "Reddit provider");
        const maps = WebSearch.parse("maps restaurants Caen");
        check(maps?.url === "https://www.google.com/maps/search/restaurants%20Caen", "Google Maps provider");

        check(WebSearch.parse("yt lofi") === null, "unsupported short YouTube prefix");
        check(WebSearch.parse("google") === null, "empty explicit provider query");
        check(WebSearch.fallback("   ") === null, "empty fallback query");

        const fallback = WebSearch.fallback("  comment   dessiner un lapin  ");
        check(fallback?.desc === "Google", "Google fallback provider");
        check(fallback?.url === "https://www.google.com/search?q=comment%20dessiner%20un%20lapin", "Google fallback URL");
        fallback.onClicked(mockList);
        check(mockList.screenState.launcher === false, "launcher closes before opening URL");
        verificationTimer.start();
    }

    Timer {
        id: verificationTimer
        interval: 250
        onTriggered: {
            if (!root.failed)
                console.log("WEBSEARCH_TEST_PASS");
            Qt.quit();
        }
    }
}
