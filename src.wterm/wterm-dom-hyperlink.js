/*! Modified for Visualize from WTerm 0.5.0. Apache-2.0; see LICENSE and README.md. */
export function isLinkActivationModifier(event, navigator) {
    return navigator.platform.startsWith("Mac") ? event.metaKey : event.ctrlKey;
}

export function textLinks(text) {
    const links = [];
    const pairs = { "(": ")", "[": "]", "{": "}" };
    for (const match of text.matchAll(/https?:\/\/[^\s<>"'\u2013\u2014\u2018\u2019\u201c\u201d]+/g)) {
        const stack = [];
        let end = 0;
        for (; end < match[0].length; end++) {
            const char = match[0][end];
            if (pairs[char]) stack.push(pairs[char]);
            else if (char === ")" || char === "]" || char === "}") {
                if (stack.pop() !== char) break;
            }
        }
        const uri = match[0].slice(0, end).replace(/[.,;:!?]+$/, "");
        links.push({ index: match.index, uri });
    }
    return links;
}
